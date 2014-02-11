// FIXME: output unions too just like structs
// FIXME: check for compatible types

// nice idea: convert modules to namespaces, but it won't work since then
// the mangles won't be right

import std.stdio;
import std.string : replace, toUpper, indexOf, strip;
import std.algorithm : map, startsWith;

string getIfThere(Variant[string] obj, string key) {
	auto ptr = key in obj;
	return ptr ? ((*ptr).get!string) : null;
}

void addLine(ref string s, string line) {
	s ~= line ~ "\n";
}

struct FunctionInfo {
	string name;
	string callingConvention;
	string typeMangle;
	string returnTypeMangle;

	struct Argument {
		string name;
		string typeMangle;
		string[] storageClass;
	}

	Argument[] arguments;

	static FunctionInfo fromJsonInfo(Variant[string] obj) {
		FunctionInfo info;

		info.name = obj["name"].get!string;
		info.typeMangle = obj["deco"].get!string;
		info.returnTypeMangle = getReturnTypeMangle(info.typeMangle);
		info.callingConvention = getCallingConvention(info.typeMangle);

		if("parameters" in obj)
		foreach(arg; map!(a => a.get!(Variant[string]))(obj["parameters"].get!(Variant[]))) {
			Argument argInfo;
			argInfo.name = getIfThere(arg, "name");
			argInfo.typeMangle = getIfThere(arg, "deco");
			if("storageClass" in arg)
			foreach(sc; map!(a => a.get!string)(arg["storageClass"].get!(Variant[])))
				argInfo.storageClass ~= sc;

			info.arguments ~= argInfo;
		}

		return info;
	}
}

string getArguments(FunctionInfo info) {
	string args = "(";
	foreach(arg; info.arguments) {
		if(args.length > 1)
			args ~= ", ";
		args ~= mangleToCType(arg.typeMangle);
		// FIXME: check storage class
		if(arg.name.length)
			args ~= " " ~ arg.name;
	}
	args ~= ")";
	return args;
}

string getReturnTypeMangle(string type) {
	auto argEnd = type.indexOf("Z");
	if(argEnd == -1)
		throw new Exception("Variadics not supported");
	return type[argEnd + 1 .. $];
}

string getCallingConvention(string type) {
	switch(type[0]) {
		case 'F': return "D";
		case 'U': return "C";
		case 'W': return "Windows";
		case 'V': return "Pascal";
		case 'R': return "C++";
		default: assert(0);
	}
}

string[] demangleName(string mangledName) {
	string[] ret;

	import std.conv;
	while(mangledName.length) {
		size_t at = 0;
		while(at < mangledName.length && mangledName[at] >= '0' && mangledName[at] <= '9')
			at++;
		auto length = to!int(mangledName[0 .. at]);
		assert(length);
		mangledName = mangledName[at .. $];
		ret ~= mangledName[0 .. length];
		mangledName = mangledName[length .. $];
	}

	return ret;
}

string mangleToCType(string mangle) {
	assert(mangle.length);

	string[string] basicTypeMapping = [
		"i"		: "long", // D int is fixed at 32 bit so I think this is more correct than using C int...
		"k"		: "unsigned long", // D's uint
		"g"		: "char", // byte
		"h"		: "unsigned char", // ubyte
		"s"		: "short",
		"t"		: "unsigned short",
		"l"		: "long long", // D's long
		"m"		: "unsigned long long", // ulong

		"f"		: "float",
		"d"		: "double",
		"e"		: "long double", // real

		"a"		: "char",
		"v"		: "void",
	];

	switch(mangle[0]) {
		case 'O': // shared
			throw new Exception("shared not supported");
		case 'H': // AA
			throw new Exception("associative arrays not supported");
		case 'G': // static array
			throw new Exception("static arrays not supported");
		case 'A': // array (slice)
			throw new Exception("D arrays not supported, instead use a pointer+length pair");
		case 'x': // const
		case 'y': // immutable
			return "const " ~ mangleToCType(mangle[1 .. $]);
		// 'Ng' == inout
		case 'P': // pointer
			return mangleToCType(mangle[1 .. $]) ~ "*";
		case 'C': // class or interface
			return demangleName(mangle[1 .. $])[$-1] ~ "*";
		case 'S': // struct
			return demangleName(mangle[1 .. $])[$-1];
		case 'E': // enum
			return demangleName(mangle[1 .. $])[$-1];
		case 'D': // delegate
			throw new Exception("Delegates are not supported");
		default:
			if(auto t = mangle in basicTypeMapping)
				return *t;
			else
				assert(0, mangle);
	}

	assert(0);
}

void main(string[] args) {
	string jsonFilename;
	bool useC;
	foreach(arg; args[1 .. $]) {
		if(arg == "-c")
			useC = true;
		else
			jsonFilename = arg;
	}
	// pointers to any of these should work, as well as static arrays of them
	// structs and interfaces are added below
	// FIXME: function pointers composed of allowed types should be ok too

	import std.file;
	auto moduleData = jsonToVariant(readText(jsonFilename)).get!(Variant[]);
	foreach(mod; map!((a) => a.get!(Variant[string]))(moduleData)) {
		auto filename = replace(mod["file"].get!string, ".d", ".h");
		auto guard = "D_" ~ toUpper(filename.replace(".", "_"));
		string fileContents;

		fileContents.addLine("#ifndef " ~ guard);
		fileContents.addLine("#define " ~ guard);
		fileContents.addLine("// generated from " ~ mod["file"].get!string);

		fileContents ~= "\n";

		auto moduleName = getIfThere(mod, "name");
		if(moduleName.length == 0)
			moduleName = filename[0 .. $-2];

		// we're going to put all imports first, since C and C++ don't do forward references
		// also going to forward declare the structs and classes as well.
		// we might need a struct/class reference, even with just prototypes
		foreach(member; map!((a) => a.get!(Variant[string]))(mod["members"].get!(Variant[]))) {
			auto name = member.getIfThere("name");
			auto kind = member.getIfThere("kind");

			switch(kind) {
				case "import":
					if(!name.startsWith("std.") && !name.startsWith("core."))
						fileContents.addLine("#include \""~name~".h\"");
				break;
				case "struct":
					fileContents.addLine("struct\t"~name~";");
				break;
				case "interface":
					fileContents.addLine("class\t"~name~";");
				break;
				default:
					// waiting for later
			}
		}

		// now, we'll do the rest of the members
		moduleMemberLoop:
		foreach(member; map!((a) => a.get!(Variant[string]))(mod["members"].get!(Variant[]))) {
			auto name = member.getIfThere("name");
			auto kind = member.getIfThere("kind");
			auto protection = member.getIfThere("protection");
			auto type = member.getIfThere("deco");

			if(protection == "private")
				continue;

			switch(kind) {
				case "function":
					string line;

					auto info = FunctionInfo.fromJsonInfo(member);
					if(info.callingConvention == "C++") {
						if(useC)
							continue;
						line ~= "extern \"C++\"\t";
					} else if(info.callingConvention == "C") {
						if(useC)
							line ~= "extern ";
						else
							line ~= "extern \"C\"\t";
					} else {
						continue;
					}

					line ~= mangleToCType(info.returnTypeMangle)
						~ " " ~ name ~ getArguments(info) ~ ";";

					fileContents.addLine(line);
				break;
				case "variable":
					// both manifest constants and module level variables show up here
					// if it is extern(C) and __gshared, the global variable should be ok...
					// but since the dmd json doesn't tell us that information, we have to assume
					// it isn't accessible.

					bool isEnum;
					bool isGshared;
					if("storageClass" in member) {
						auto sc = member["storageClass"].get!(Variant[]);
						foreach(c; sc)
							if(c.get!string == "enum") {
								isEnum = true;
								break;
							} else if(c.get!string == "__gshared") {
								isGshared = true;
							}
					}

					if(isEnum) {
						auto line = "#define " ~ name ~ " ";
						line ~= member.getIfThere("init");
						fileContents.addLine(line);
					} else {
						string line = "extern ";
						if(!isGshared)
							//line ~= "__declspec(thread) ";
							continue moduleMemberLoop; // TLS not supported in this
						fileContents.addLine(line ~ mangleToCType(type) ~ " " ~ name ~ ";");
					}

					// this space intentionally left blank until dmd is fixed
				break;
				case "enum":
					// enums should be ok... but dmd's json doesn't tell us the value of the members,
					// only the names

					// since the value is important for C++ to get it right, we can't use these either

					// this space intentionally left blank until dmd is fixed
				break;
				case "struct":
					// plain structs are cool. We'll keep them with data members only, no functions.
					// If it has destructors or postblits, that's no good, C++ won't know. So we'll
					// output them only as opaque types.... if dmd only told us!
					// FIXME: when dmd is fixed, check out the destructor dilemma

					string line;

					line ~= "\ntypedef struct " ~ name ~ " {";

					foreach(method; map!((a) => a.get!(Variant[string]))(member["members"].get!(Variant[]))) {
						auto memName = method.getIfThere("name");
						auto memType = method.getIfThere("deco");
						auto memKind = method.getIfThere("kind");

						// if it has a dtor, we want this to be an opaque type only since
						// otherwise it won't be used correctly in C++
						if(memKind == "destructor")
							continue moduleMemberLoop;

						if(memKind != "variable")
							continue;

						line ~= "\n\t";
						line ~= mangleToCType(memType) ~ " " ~ memName ~ ";";
					}

					line ~= "\n} " ~ name ~ ";\n";
					fileContents.addLine(line);
				break;
				case "interface":
					if(useC)
						continue;
					// FIXME: the json doesn't seem to say if interfaces are extern C++ or not

					string line;

					line ~= "\nclass " ~ name ~ " {\n\tpublic:";

					foreach(method; map!((a) => a.get!(Variant[string]))(member["members"].get!(Variant[]))) {
						line ~= "\n\t\t";

						auto info = FunctionInfo.fromJsonInfo(method);

						if(info.callingConvention != "C++") {
								continue;
						}

						auto returnType = mangleToCType(info.returnTypeMangle);
						auto arguments = getArguments(info);

						line ~= "virtual " ~ returnType ~ " " ~ info.name ~ arguments ~ " = 0;";
					}

					line ~= "\n};\n";

					fileContents.addLine(line);
				break;
				default: // do nothing
			}
		}

		fileContents.addLine("\n#endif");

		if(exists(filename)) {
			auto existingFile = readText(filename);
			if(existingFile == fileContents)
				continue;
		}

		std.file.write(filename, fileContents);
	}
}



// helpers tomake std.json easier to use
import std.variant;
import std.json;

Variant jsonToVariant(string json) {
	auto decoded = parseJSON(json);
	return jsonValueToVariant(decoded);
}

Variant jsonValueToVariant(JSONValue v) {
	Variant ret;

	final switch(v.type) {
		case JSON_TYPE.STRING:
			ret = v.str;
		break;
		case JSON_TYPE.UINTEGER:
			ret = v.uinteger;
		break;
		case JSON_TYPE.INTEGER:
			ret = v.integer;
		break;
		case JSON_TYPE.FLOAT:
			ret = v.floating;
		break;
		case JSON_TYPE.OBJECT:
			Variant[string] obj;
			foreach(k, val; v.object) {
				obj[k] = jsonValueToVariant(val);
			}

			ret = obj;
		break;
		case JSON_TYPE.ARRAY:
			Variant[] arr;
			foreach(i; v.array) {
				arr ~= jsonValueToVariant(i);
			}

			ret = arr;
		break;
		case JSON_TYPE.TRUE:
			ret = true;
		break;
		case JSON_TYPE.FALSE:
			ret = false;
		break;
		case JSON_TYPE.NULL:
			ret = null;
		break;
	}

	return ret;
}

