// FIXME: output unions too just like structs
// FIXME: check for compatible types


enum usage = 
"Usage: dtoh [-c] [-h] file.json

To generate a .json file, use dmd -X yourfile.d

Options:
	-c    generate C instead of C++
	-h    display this help

The generated .h file can then be included in your
C or C++ project, giving easy access to extern(C)
and extern(C++) D functions and interfaces.
";

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

int indexOfArguments(string type) {
	int parenCount = 0;
	foreach_reverse(i, c; type) {
		if(c == ')')
			parenCount++;
		if(c == '(')
			parenCount--;
		if(parenCount == 0)
			return i;
	}

	assert(0);
}

string getReturnType(string type, string[string] typeMapping) {
	if(type.startsWith("extern")) {
		type = type[type.indexOf(")") + 2 .. $]; // skip the ) and a space
	}

	auto t = type[0 .. indexOfArguments(type)];
	if(t in typeMapping)
		return typeMapping[t];
	return "void";
}

string getArguments(string type, string[string] typeMapping) {
	auto argList = type[indexOfArguments(type) .. $][1 .. $-1]; // cutting the parens

	string newArgList;

	void handleArg(string arg) {
		if(arg.length > 0 && arg[0] == ' ')
			arg = arg[1 .. $];
		if(arg.length == 0)
			return;

		if(newArgList.length)
			newArgList ~= ", ";

		auto fullArg = arg;
		string moreArg;
		foreach(i, c; fullArg) {
			if(c == '*' || c == '[' || c == '!') {
				arg = fullArg[0 .. i];
				moreArg = fullArg[i .. $];
				break;
			}
		}

		auto cppArg = arg in typeMapping;
		newArgList ~= cppArg ? *cppArg : "void /* "~arg~" */";
		newArgList ~= moreArg; // pointer, etc
	}

	bool gotName;
	int argStart;
	int parensCount;
	foreach(i, c; argList) {
		if(c == '(' || c == '[')
			parensCount++;

		if(parensCount) {
			if(c == ')' || c == ']') {
				parensCount--;
			}
			continue;
		}

		if(c == ' ') {
			handleArg(argList[argStart .. i]);
			gotName = true;
			argStart = i;
		}

		if(c == ',') {
			if(gotName) {
				newArgList ~= argList[argStart .. i];
			} else {
				handleArg(argList[argStart .. i]);
			}

			gotName = false;
			argStart = i + 1;
		}
	}

	if(gotName) {
		newArgList ~= argList[argStart .. $];
	} else {
		handleArg(argList[argStart .. $]);
	}

	return "(" ~ newArgList ~ ")";
}

void main(string[] args) {
	try {
		string jsonFilename;
		bool useC;
		foreach(arg; args[1 .. $]) {
			if(arg == "-c")
				useC = true;
			else if(arg == "-h") {
				writef("%s", usage);
				return;
			} else
				jsonFilename = arg;
		}

		if(jsonFilename.length == 0) {
			writeln("No filename given, for help use dtoh -h");
			return;
		}

		string[string] typeMapping = [
			"int"		: "int",
			"uint"		: "unsigned int",
			"byte"		: "char",
			"ubyte"		: "unsigned char",
			"short"		: "short",
			"ushort"	: "unsigned short",
			"long"		: "long long",
			"ulong"		: "unsigned long long",

			"float"		: "float",
			"double"	: "double",
			"real"		: "long double",

			"char"		: "char",
			"void"		: "void",
		];
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

			fileContents ~= "\n";

			foreach(member; map!((a) => a.get!(Variant[string]))(mod["members"].get!(Variant[]))) {
				auto name = member.getIfThere("name");
				auto kind = member.getIfThere("kind");

				if(kind == "struct") {
					typeMapping[name] = name;
				} else if(kind == "enum") {
					// see the note on enum below, in the main switch
					// we can't output the declarations very well, so we'll just map
					// these to the base type so we at least have something

					auto base = member.getIfThere("base");
					if(base.length && base in typeMapping) {
						typeMapping[name] = typeMapping[base];
					}
				} else if(!useC && kind == "interface") {
					typeMapping[name] = name ~ "*"; // D interfaces are represented as class pointers in C++
				}
			}

			moduleMemberLoop:
			foreach(member; map!((a) => a.get!(Variant[string]))(mod["members"].get!(Variant[]))) {
				auto name = member.getIfThere("name");
				auto kind = member.getIfThere("kind");
				auto protection = member.getIfThere("protection");
				auto type = member.getIfThere("type");

				if(protection == "private")
					continue;

				switch(kind) {
					case "function":
						string line;
						if(type.indexOf("extern (C++)") != -1) {
							if(useC)
								continue;
							line ~= "extern \"C++\"\t";
						} else if(type.indexOf("extern (C)") != -1) {
							if(useC)
								line ~= "extern ";
							else
								line ~= "extern \"C\"\t";
						} else {
							continue;
						}

						auto returnType = getReturnType(type, typeMapping);
						auto arguments = getArguments(type, typeMapping);

						line ~= returnType ~ " " ~ name ~ arguments ~ ";";

						fileContents.addLine(line);
					break;
					case "variable":
						// both manifest constants and module level variables show up here
						// if it is extern(C) and __gshared, the global variable should be ok...
						// but since the dmd json doesn't tell us that information, we have to assume
						// it isn't accessible.

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
							auto memType = method.getIfThere("type");

							if(method.getIfThere("kind") != "variable")
								continue;

							line ~= "\n\t";
							if(auto cType = (memType in typeMapping))
								line ~= *cType ~ " " ~ memName ~ ";";
							else assert(0, memType);
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

							auto funcName = method.getIfThere("name");
							auto funcType = method.getIfThere("type");

							if(funcType.indexOf("extern (C++)") == -1) {
									continue;
							}

							auto returnType = getReturnType(funcType, typeMapping);
							auto arguments = getArguments(funcType, typeMapping);

							line ~= "virtual " ~ returnType ~ " " ~ funcName ~ arguments ~ " = 0;";
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
	} catch(Throwable t) {
		writeln(t.toString());
		writef("%s", usage);
	}
}




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

