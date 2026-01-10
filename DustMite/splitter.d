/// Simple source code splitter
/// Written by Vladimir Panteleev <vladimir@thecybershadow.net>
/// License: Boost Software License, Version 1.0

module splitter;

import std.ascii;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime.systime;
import std.exception;
import std.file;
import std.functional;
import std.path;
import std.range;
import std.stdio : File, stdin;
import std.string;
import std.traits;
import std.stdio : stderr;
import std.typecons;
import std.utf : byChar;

import polyhash;

/// Represents an Entity's position within a program tree.
struct Address
{
	Address* parent;       /// Upper node's Address. If null, then this is the root node (and index should be 0).
	size_t index;          /// Index within the parent's children array
	size_t depth;          /// Distance from the root address

	Address*[] children;   /// Used to keep a global cached tree of addresses.
	ref Address* child(size_t index) const
	{
		auto mutableThis = cast(Address*)&this; // Break const for caching
		if (mutableThis.children.length < index + 1)
			mutableThis.children.length = index + 1;
		if (!mutableThis.children[index])
			mutableThis.children[index] = new Address(mutableThis, index, depth+1);
		return mutableThis.children[index];
	}
}

struct EntityRef             /// Reference to another Entity in the same tree
{
	Entity entity;           /// Pointer - only valid during splitting / optimizing
	const(Address)* address; /// Address - assigned after splitting / optimizing
}

enum largest64bitPrime = 18446744073709551557UL; // 0xFFFFFFFF_FFFFFFC5
// static if (is(ModQ!(ulong, largest64bitPrime)))
static if (modQSupported) // https://issues.dlang.org/show_bug.cgi?id=20677
	alias EntityHash = PolynomialHash!(ModQ!(ulong, largest64bitPrime));
else
{
	pragma(msg,
		"64-bit long multiplication/division is not supported on this platform.\n" ~
		"Falling back to working in modulo 2^^64.\n" ~
		"Hashing / cache accuracy may be impaired.\n" ~
		"---------------------------------------------------------------------");
	alias EntityHash = PolynomialHash!ulong;
}

/// Represents a slice of the original code.
final class Entity
{
	string head;           /// This node's "head", e.g. "{" for a statement block.
	Entity[] children;     /// This node's children nodes, e.g. the statements of the statement block.
	string tail;           /// This node's "tail", e.g. "}" for a statement block.

	string contents;

	struct FileProperties
	{
		string name;       /// Relative to the reduction root
		Nullable!uint mode; /// OS-specific (std.file.getAttributes)
		Nullable!(SysTime[2]) times; /// Access and modification times
	}
	FileProperties* file;  /// If non-null, this node represents a file

	bool isPair;           /// Internal hint for --dump output
	bool noRemove;         /// Don't try removing this entity (children OK)
	bool clean;            /// Computed fields are up-to-date

	bool dead;             /// Tombstone or redirect
	EntityRef[] dependents;/// If this entity is removed, so should all these entities.
	Address* redirect;     /// If moved, this is where this entity is now

	int id;                /// For diagnostics
	size_t descendants;    /// [Computed] For progress display
	EntityHash hash;       /// [Computed] Hashed value of this entity's content (as if it were saved to disk).
	const(Address)*[] allDependents; /// [Computed] External dependents of this and child nodes
	string deadContents;   /// [Computed] For --white-out - all of this node's contents, with non-whitespace replaced by whitespace
	EntityHash deadHash;   /// [Computed] Hash of deadContents

	this(string head = null, Entity[] children = null, string tail = null)
	{
		this.head     = head;
		this.children = children;
		this.tail     = tail;
	}

	@property string comment()
	{
		string[] result;
		debug result = comments;
		if (isPair)
		{
			assert(token == DSplitter.Token.none);
			result ~= "Pair";
		}
		if (token && DSplitter.tokenText[token])
			result ~= DSplitter.tokenText[token];
		return result.length ? result.join(" / ") : null;
	}

	override string toString() const
	{
		return "%(%s%) %s %(%s%)".format([head], children, [tail]);
	}

	Entity dup()           /// Creates a shallow copy
	{
		auto result = new Entity;
		foreach (i, item; this.tupleof)
			result.tupleof[i] = this.tupleof[i];
		result.children = result.children.dup;
		return result;
	}

	void kill()            /// Convert to tombstone/redirect
	{
		dependents = null;
		isPair = false;
		descendants = 0;
		allDependents = null;
		dead = true;
	}

private: // Used during parsing only
	DSplitter.Token token;    /// Used internally

	debug string[] comments;  /// Used to debug the splitter
}

enum Splitter
{
	files,     /// Load entire files only
	lines,     /// Split by line ends
	null_,     /// Split by the \0 (NUL) character
	words,     /// Split by whitespace
	D,         /// Parse D source code
	diff,      /// Unified diffs
	indent,    /// Indentation (Python, YAML...)
	lisp,      /// Lisp and similar languages
}
immutable string[] splitterNames = [EnumMembers!Splitter].map!(e => e.text().toLower().chomp("_")).array();

struct ParseRule
{
	string pattern;
	Splitter splitter;
}

struct ParseOptions
{
	enum Mode
	{
		source,
		words,     /// split identifiers, for obfuscation
		json,
	}

	bool stripComments;
	ParseRule[] rules;
	Mode mode;
	uint tabWidth;
}

version (Posix) {} else
{
	// Non-POSIX symlink stubs
	string readLink(const(char)[]) { throw new Exception("Sorry, symbolic links are only supported on POSIX systems"); }
	void symlink(const(char)[], const(char)[]) { throw new Exception("Sorry, symbolic links are only supported on POSIX systems"); }
}

/// Parse the given file/directory.
/// For files, modifies `path` to be the base name for .test / .reduced directories.
Entity loadFiles(ref string path, ParseOptions options)
{
	if (path != "-" && !path.isSymlink && path.exists && path.isDir)
	{
		auto set = new Entity();
		foreach (string entry; dirEntries(path, SpanMode.breadth, /*followSymlink:*/false).array.sort!((a, b) => a.name < b.name))
			if (isSymlink(entry) || isFile(entry) || isDir(entry))
			{
				assert(entry.startsWith(path));
				auto name = entry[path.length+1..$];
				set.children ~= loadFile(name, entry, options);
			}
		return set;
	}
	else
	{
		auto realPath = path;
		string name; // For Entity.filename
		if (path == "-" || path == "/dev/stdin")
			name = path = "stdin";
		else
			name = realPath.baseName();
		return loadFile(name, realPath, options);
	}
}

enum BIN_SIZE = 2;

void optimizeUntil(alias stop)(Entity set)
{
	static Entity group(Entity[] children)
	{
		if (children.length == 1)
			return children[0];
		auto e = new Entity(null, children, null);
		e.noRemove = children.any!(c => c.noRemove)();
		return e;
	}

	static void clusterBy(ref Entity[] set, size_t binSize)
	{
		while (set.length > binSize)
		{
			auto size = set.length >= binSize*2 ? binSize : (set.length+1) / 2;
			//auto size = binSize;

			set = set.chunks(size).map!group.array;
		}
	}

	void doOptimize(Entity e)
	{
		if (stop(e))
			return;
		foreach (c; e.children)
			doOptimize(c);
		clusterBy(e.children, BIN_SIZE);
	}

	doOptimize(set);
}

alias optimize = optimizeUntil!((Entity e) => false);

private:

/// Override std.string nonsense, which does UTF-8 decoding
bool startsWith(in char[] big, in char[] small) { return big.length >= small.length && big[0..small.length] == small; }
bool startsWith(in char[] big, char c) { return big.length && big[0] == c; }
string strip(string s) { while (s.length && isWhite(s[0])) s = s[1..$]; while (s.length && isWhite(s[$-1])) s = s[0..$-1]; return s; }

immutable ParseRule[] defaultRules =
[
	{ "*.d"    , Splitter.D     },
	{ "*.di"   , Splitter.D     },

	{ "*.diff" , Splitter.diff  },
	{ "*.patch", Splitter.diff  },

	{ "*.lisp" , Splitter.lisp  },
	{ "*.cl"   , Splitter.lisp  },
	{ "*.lsp"  , Splitter.lisp  },
	{ "*.el"   , Splitter.lisp  },

	{ "*"      , Splitter.files },
];

void[] readFile(File f)
{
	import std.range.primitives : put;
	auto result = appender!(ubyte[]);
	auto size = f.size;
	if (size <= uint.max)
		result.reserve(cast(size_t)size);
	put(result, f.byChunk(64 * 1024));
	return result.data;
}

Entity loadFile(string name, string path, ParseOptions options)
{
	auto base = name.baseName();
	Splitter splitterType = chain(options.rules, defaultRules).find!(rule => base.globMatch(rule.pattern)).front.splitter;

	Nullable!uint mode;
	if (path != "-")
	{
		mode = getLinkAttributes(path);
		if (attrIsSymlink(mode.get()) || attrIsDir(mode.get()))
			splitterType = Splitter.files;
	}

	stderr.writeln("Loading ", path, " [", splitterType, "]");
	auto contents =
		attrIsSymlink(mode.get(0)) ? path.readLink() :
		attrIsDir(mode.get(0)) ? null :
		cast(string)readFile(path == "-" ? stdin : File(path, "rb"));

	if (options.mode == ParseOptions.Mode.json)
		return loadJson(contents);

	auto result = new Entity();
	result.file = new Entity.FileProperties;
	result.file.name = name.replace(dirSeparator, `/`);
	result.file.mode = mode;
	if (!mode.isNull() && !attrIsSymlink(mode.get()) && path != "-")
	{
		SysTime accessTime, modificationTime;
		getTimes(path, accessTime, modificationTime);
		result.file.times = [accessTime, modificationTime];
	}
	result.contents = contents;

	final switch (splitterType)
	{
		case Splitter.files:
			result.children = [new Entity(result.contents, null, null)];
			break;
		case Splitter.lines:
			result.children = parseToLines(result.contents);
			break;
		case Splitter.words:
			result.children = parseToWords(result.contents);
			break;
		case Splitter.null_:
			result.children = parseToNull(result.contents);
			break;
		case Splitter.D:
			if (result.contents.startsWith("Ddoc"))
				goto case Splitter.files;

			DSplitter splitter;
			if (options.stripComments)
				result.contents = splitter.stripComments(result.contents);

			final switch (options.mode)
			{
				case ParseOptions.Mode.json:
					assert(false);
				case ParseOptions.Mode.source:
					result.children = splitter.parse(result.contents);
					break;
				case ParseOptions.Mode.words:
					result.children = splitter.parseToWords(result.contents);
					break;
			}
			break;
		case Splitter.diff:
			result.children = parseDiff(result.contents);
			break;
		case Splitter.indent:
			result.children = parseIndent(result.contents, options.tabWidth);
			break;
		case Splitter.lisp:
			result.children = parseLisp(result.contents);
			break;
	}

	debug
	{
		string resultContents;
		void walk(Entity[] entities) { foreach (e; entities) { resultContents ~= e.head; walk(e.children); resultContents ~= e.tail; }}
		walk(result.children);
		assert(result.contents == resultContents, "Contents mismatch after splitting:\n" ~ resultContents);
	}

	return result;
}

// *****************************************************************************************************************************************************************************

/// A simple, error-tolerant D source code splitter.
struct DSplitter
{
	struct Pair { string start, end; }
	static const Pair[] pairs =
	[
		{ "{", "}" },
		{ "[", "]" },
		{ "(", ")" },
	];

	static immutable string[] blockKeywords = ["try", "catch", "finally", "while", "do", "in", "out", "body", "if", "static if", "else", "for", "foreach"];
	static immutable string[] parenKeywords = ["catch", "while", "if", "static if", "for", "foreach"];

	/// The order dictates the splitting priority of the separators.
	static immutable string[][] separators =
	[
		[";", "{"] ~ blockKeywords,
		["import"],
		// From http://wiki.dlang.org/Operator_precedence
		// Some items are listed twice, DustMite does not distinguish binary/prefix/postfix operators
		[".."],
		[","],
		["=>"],
		["=", "-=", "+=", "<<=", ">>=", ">>>=", "=", "*=", "%=", "^=", "^^=", "~="],
		["?", ":"],
		["||"],
		["&&"],
		["|"],
		["^"],
		["&"],
		["==", "!=", ">", "<", ">=", "<=", "!>", "!<", "!>=", "!<=", "<>", "!<>", "<>=", "!<>=", "in", "!in", "is", "!is"],
		["<<", ">>", ">>>"],
		["+", "-", "~"],
		["*", "/", "%"],
		["&", "++", "--", "*", "+", "-", /*"!",*/ "~"],
		["^^"],
		[".", "++", "--" /*, "(", "["*/],
		// "=>",
		["!"],
		["(", "["]
	];

	enum Token : int
	{
		none,
		end,        /// end of stream
		whitespace, /// spaces, tabs, newlines
		comment,    /// all forms of comments
		other,      /// identifiers, literals and misc. keywords

		generated0, /// First value of generated tokens (see below)

		max = tokenText.length
	}

	static immutable string[] tokenText =
	{
		auto result = new string[Token.generated0];
		Token[string] lookup;

		Token add(string s)
		{
			auto p = s in lookup;
			if (p)
				return *p;

			Token t = cast(Token)result.length;
			result ~= s;
			lookup[s] = t;
			return t;
		}

		foreach (pair; pairs)
		{
			add(pair.start);
			add(pair.end  );
		}

		foreach (i, synonyms; separators)
			foreach (sep; synonyms)
				add(sep);
		return result;
	}();

	static Token lookupToken(string s)
	{
		if (!__ctfe) assert(false, "Don't use at runtime");
		foreach (t; Token.generated0 .. Token.max)
			if (s == tokenText[t])
				return t;
		assert(false, "No such token: " ~ s);
	}
	enum Token tokenLookup(string s) = lookupToken(s);

	struct TokenPair { Token start, end; }
	static TokenPair makeTokenPair(Pair pair) { return TokenPair(lookupToken(pair.start), lookupToken(pair.end)); }
	alias lookupTokens = arrayMap!(lookupToken, const string);
	static immutable TokenPair[] pairTokens      = pairs     .arrayMap!makeTokenPair();
	static immutable Token[][]   separatorTokens = separators.arrayMap!lookupTokens ();
	static immutable Token[] blockKeywordTokens = blockKeywords.arrayMap!lookupToken();
	static immutable Token[] parenKeywordTokens = parenKeywords.arrayMap!lookupToken();

	enum SeparatorType
	{
		none,
		pair,
		prefix,
		postfix,
		binary,  /// infers dependency
	}

	static SeparatorType getSeparatorType(Token t)
	{
		switch (t)
		{
			case tokenLookup!";":
				return SeparatorType.postfix;
			case tokenLookup!"import":
				return SeparatorType.prefix;
			case tokenLookup!"else":
				return SeparatorType.binary;
			default:
				if (pairTokens.any!(pair => pair.start == t))
					return SeparatorType.pair;
				if (blockKeywordTokens.canFind(t))
					return SeparatorType.prefix;
				if (separatorTokens.any!(row => row.canFind(t)))
					return SeparatorType.binary;
				return SeparatorType.none;
		}
	}

	// ************************************************************************

	string s; /// Source code we are splitting
	size_t i; /// Cursor

	/// Making the end of an input stream a throwable greatly simplifies control flow.
	class EndOfInput : Throwable { this() { super(null); } }

	/// Are we at the end of the stream?
	@property bool eos() { return i >= s.length; }

	/// Advances i by n bytes. Throws EndOfInput if there are not enough.
	string advance(size_t n)
	{
		auto e = i + n;
		if (e > s.length)
		{
			i = s.length;
			throw new EndOfInput;
		}
		auto result = s[i..e];
		i = e;
		return result;
	}

	/// ditto
	char advance() { return advance(1)[0]; }

	/// If pre comes next, advance i through pre and return it.
	/// Otherwise, return null.
	string consume(string pre)
	{
		if (s[i..$].startsWith(pre))
			return advance(pre.length);
		else
			return null;
	}

	/// ditto
	char consume(char pre)
	{
		assert(pre);
		if (s[i..$].startsWith(pre))
			return advance();
		else
			return 0;
	}

	/// Peeks at the next n characters.
	string peek(size_t n)
	{
		if (i+n > s.length)
			throw new EndOfInput;
		return s[i..i+n];
	}

	/// ditto
	char peek() { return peek(1)[0]; }

	/// Advances i through one token (whether it's a comment,
	/// a series of whitespace characters, or something else).
	/// Returns the token type.
	Token skipTokenOrWS()
	{
		if (eos)
			return Token.end;

		Token result = Token.other;
		try
		{
			auto c = advance();
			switch (c)
			{
			case '\'':
				result = Token.other;
				if (consume('\\'))
					advance();
				while (advance() != '\'')
					continue;
				break;
			case '\\':  // D1 naked escaped string
				result = Token.other;
				advance();
				break;
			case '"':
				result = Token.other;
				while (peek() != '"')
				{
					if (advance() == '\\')
						advance();
				}
				advance();
				break;
			case 'r':
				if (consume(`"`))
				{
					result = Token.other;
					while (advance() != '"')
						continue;
					break;
				}
				else
					goto default;
			case '`':
				result = Token.other;
				while (advance() != '`')
					continue;
				break;
			case '/':
				if (consume('/'))
				{
					result = Token.comment;
					while (peek() != '\r' && peek() != '\n')
						advance();
				}
				else
				if (consume('*'))
				{
					result = Token.comment;
					while (!consume("*/"))
						advance();
				}
				else
				if (consume('+'))
				{
					result = Token.comment;
					int commentLevel = 1;
					while (commentLevel)
					{
						if (consume("/+"))
							commentLevel++;
						else
						if (consume("+/"))
							commentLevel--;
						else
							advance();
					}
				}
				else
					goto default;
				break;
			case '@':
				if (consume("disable")
				 || consume("property")
				 || consume("safe")
				 || consume("trusted")
				 || consume("system")
				)
					return Token.other;
				goto default;
			case '#':
				result = Token.other;
				do
				{
					c = advance();
					if (c == '\\')
						c = advance();
				}
				while (c != '\n');
				break;
			default:
				{
					i--;
					Token best;
					size_t bestLength;
					foreach (Token t; Token.init..Token.max)
					{
						auto text = tokenText[t];
						if (!text)
							continue;
						if (!s[i..$].startsWith(text))
							continue;
						if (text[$-1].isAlphaNum() && s.length > i + text.length && s[i + text.length].isAlphaNum())
							continue; // if the token is a word, it must end at a word boundary
						if (text.length <= bestLength)
							continue;
						best = t;
						bestLength = text.length;
					}
					if (bestLength)
					{
						auto consumed = consume(tokenText[best]);
						assert(consumed);
						return best;
					}

					i++;
				}
				if (c.isWhite())
				{
					result = Token.whitespace;
					while (peek().isWhite())
						advance();
				}
				else
				if (isWordChar(c))
				{
					result = Token.other;
					while (isWordChar(peek()))
						advance();
				}
				else
					result = Token.other;
			}
		}
		catch (EndOfInput)
			i = s.length;
		return result;
	}

	/// Skips leading and trailing whitespace/comments, too.
	/// Never returns Token.whitespace or Token.comment.
	void readToken(out Token type, out string span)
	{
		size_t spanStart = i;
		do
			type = skipTokenOrWS();
		while (type == Token.whitespace || type == Token.comment);
		skipToEOL();
		span = s[spanStart..i];
		if (type == Token.end && span.length)
			type = Token.whitespace;
	}

	/// Moves i forward over first series of EOL characters,
	/// or until first non-whitespace character, whichever comes first.
	void skipToEOL()
	{
		try
			while (true)
			{
				auto c = peek();
				if (c == '\r' || c == '\n')
				{
					do
						advance(), c = peek();
					while (c == '\r' || c == '\n');
					return;
				}
				else
				if (c.isWhite())
					i++;
				else
				if (peek(2) == "//")
				{
					auto t = skipTokenOrWS();
					assert(t == Token.comment);
				}
				else
					break;
			}
		catch (EndOfInput)
			i = s.length;
	}

	static bool isWordChar(char c)
	{
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
	}

	void reset(string code)
	{
		s = code;
		i = 0;
	}

	void parseScope(Entity result, Token scopeEnd)
	{
		enum Level : int
		{
			zero,
			separator0,
			separatorMax = separator0 + separators.length - 1,
			text,
			max
		}

		Entity[][Level.max] splitterQueue;

		Entity[] terminateLevel(Level level)
		{
			level++;
			if (level == Level.max)
				return null;

			auto r = splitterQueue[level] ~ group(terminateLevel(level));
			splitterQueue[level] = null;
			return r;
		}

		while (true)
		{
			Token token;
			string span;
			readToken(token, span);

			if (token == Token.end)
			{
				assert(span.empty);
				break;
			}
			if (token == scopeEnd)
			{
				result.tail = span;
				break;
			}

			auto e = new Entity();
			e.token = token;
			auto level = Level.text;

			Entity after;

			foreach (n, synonyms; separatorTokens)
				foreach (sep; synonyms)
					if (token == sep)
					{
						level = cast(Level)(Level.separator0 + n);
						e.children = terminateLevel(level);
						auto type = getSeparatorType(token);
						if (type == SeparatorType.prefix || type == SeparatorType.pair)
						{
							Entity empty = e;
							if (e.children.length)
							{
								e.token = Token.none;
								after = empty = new Entity(span);
								after.token = token;
							}
							else
								e.head = span;

							if (type == SeparatorType.pair)
								parseScope(empty, pairTokens.find!(pair => pair.start == token).front.end);
						}
						else
							e.tail = span;
						goto handled;
					}

			e.head = span;

		handled:
			splitterQueue[level] ~= e;
			if (after)
				splitterQueue[level] ~= after;
		}

		result.children ~= terminateLevel(Level.zero);
	}

	Entity[] parse(string code)
	{
		reset(code);
		auto entity = new Entity;
		parseScope(entity, Token.none);
		assert(!entity.head && !entity.tail);
		postProcess(entity.children);
		return [entity];
	}

	Entity[] parseToWords(string code)
	{
		reset(code);
		Entity[] result;
		while (!eos)
		{
			auto start = i;
			auto token = skipTokenOrWS();
			auto span = s[start..i];

			if (token == Token.other)
				result ~= new Entity(span);
			else
			{
				if (!result.length)
					result ~= new Entity();
				if (!result[$-1].tail)
					result[$-1].tail = span;
				else
				{
					start = result[$-1].tail.ptr - s.ptr;
					result[$-1].tail = s[start..i];
				}
			}
		}
		return result;
	}

	string stripComments(string code)
	{
		reset(code);
		auto result = appender!string();
		while (!eos)
		{
			auto start = i;
			Token t = skipTokenOrWS();
			if (t != Token.comment)
				result.put(s[start..i]);
		}
		return result.data;
	}

	static Entity[] group(Entity[] entities)
	{
		if (entities.length <= 1)
			return entities;
		return [new Entity(null, entities, null)];
	}

	static void postProcessSimplify(ref Entity[] entities)
	{
		for (size_t i=0; i<entities.length;)
		{
			auto e = entities[i];
			if (e.head.empty && e.tail.empty && e.dependents.empty)
			{
				assert(e.token == Token.none);
				if (e.children.length == 0)
				{
					entities = entities.remove(i);
					continue;
				}
				else
				if (e.children.length == 1)
				{
					entities[i] = e.children[0];
					continue;
				}
			}

			i++;
		}
	}

	// Join together module names. We should not attempt to reduce "import std.stdio" to "import std" (or "import stdio").
	static void postProcessImports(ref Entity[] entities)
	{
		if (entities.length && entities[0].head.strip == "import" && !entities[0].children.length && !entities[0].tail.length)
			foreach (entity; entities[1 .. $])
			{
				static void visit(Entity entity)
				{
					static bool isValidModuleName(string s) { return s.byChar.all!(c => isWordChar(c) || isWhite(c) || c == '.'); }
					static bool canBeMerged(Entity entity)
					{
						return
							isValidModuleName(entity.head) &&
							entity.children.all!(child => canBeMerged(child)) &&
							isValidModuleName(entity.tail);
					}

					if (canBeMerged(entity))
					{
						auto root = entity;
						// Link all ancestors to the root, and in reverse, therefore making them inextricable.
						void link(Entity entity)
						{
							entity.dependents ~= EntityRef(root);
							// root.dependents ~= EntityRef(entity);
							foreach (child; entity.children)
								link(child);
						}
						foreach (child; entity.children)
							link(child);
					}
					else
					{
						foreach (child; entity.children)
							visit(child);
					}
				}

				foreach (child; entity.children)
					visit(child);
			}
	}

	static void postProcessDependency(ref Entity[] entities)
	{
		if (entities.length < 2)
		{
			foreach (e; entities)
				postProcessDependency(e.children);
			return;
		}

		size_t[] points;
		foreach_reverse (i, e; entities[0..$-1])
			if (getSeparatorType(e.token) == SeparatorType.binary && e.children)
				points ~= i;

		if (points.length)
		{
			auto i = points[$/2];
			auto e = entities[i];

			auto head = entities[0..i] ~ group(e.children);
			e.children = null;
			auto tail = new Entity(null, group(entities[i+1..$]), null);
			tail.dependents ~= EntityRef(e);
			entities = group(head ~ e) ~ tail;
			foreach (c; entities)
				postProcessDependency(c.children);
		}
	}

	static void postProcessTemplates(ref Entity[] entities)
	{
		if (!entities.length)
			return;
		foreach_reverse (i, e; entities[0..$-1])
			if (e.token == tokenLookup!"!" && entities[i+1].children.length && entities[i+1].children[0].token == tokenLookup!"(")
			{
				auto dependency = new Entity;
				dependency.dependents = [EntityRef(e), EntityRef(entities[i+1].children[0])];
				entities = entities[0..i+1] ~ dependency ~ entities[i+1..$];
			}
	}

	static void postProcessDependencyBlock(ref Entity[] entities)
	{
		foreach (i, e; entities)
			if (i && !e.token && e.children.length && getSeparatorType(e.children[0].token) == SeparatorType.binary && !e.children[0].children)
				entities[i-1].dependents ~= EntityRef(e.children[0]);
	}

	static void postProcessBlockKeywords(ref Entity[] entities)
	{
		foreach_reverse (i; 0 .. entities.length)
		{
			if (blockKeywordTokens.canFind(entities[i].token) && i+1 < entities.length)
			{
				auto j = i + 1;
				if (j < entities.length && entities[j].token == tokenLookup!"(")
					j++;
				j++; // ; or {
				if (j <= entities.length)
					entities = entities[0..i] ~ group(group(entities[i..j-1]) ~ entities[j-1..j]) ~ entities[j..$];
			}
		}
	}

	static void postProcessBlockStatements(ref Entity[] entities)
	{
		for (size_t i=0; i<entities.length;)
		{
			auto j = i;
			bool consume(Token t)
			{
				if (j < entities.length
				 && entities[j].children.length == 2
				 && firstToken(entities[j].children[0]) == t)
				{
					j++;
					return true;
				}
				return false;
			}

			if (consume(tokenLookup!"if") || consume(tokenLookup!"static if"))
				consume(tokenLookup!"else");
			else
			if (consume(tokenLookup!"do"))
				consume(tokenLookup!"while");
			else
			if (consume(tokenLookup!"try"))
			{
				while (consume(tokenLookup!"catch"))
					continue;
				consume(tokenLookup!"finally");
			}

			if (i == j)
			{
				j++;
				while (consume(tokenLookup!"in") || consume(tokenLookup!"out") || consume(tokenLookup!"body"))
					continue;
			}

			if (j-i > 1)
			{
				entities = entities[0..i] ~ group(entities[i..j]) ~ entities[j..$];
				continue;
			}

			i++;
		}
	}

	static void postProcessPairs(ref Entity[] entities)
	{
		size_t lastPair = 0;

		for (size_t i=0; i<entities.length;)
		{
			// Create pair entities

			if (entities[i].token == tokenLookup!"{")
			{
				if (i >= lastPair + 1)
				{
					lastPair = i-1;
					entities = entities[0..lastPair] ~ group(group(entities[lastPair..i]) ~ entities[i]) ~ entities[i+1..$];
					i = lastPair;
					entities[i].isPair = true;
					lastPair++;
					continue;
				}
				else
					lastPair = i + 1;
			}
			else
			if (entities[i].token == tokenLookup!";")
				lastPair = i + 1;

			i++;
		}
	}

	static void postProcessParens(ref Entity[] entities)
	{
		for (size_t i=0; i+1 < entities.length;)
		{
			if (parenKeywordTokens.canFind(entities[i].token))
			{
				auto pparen = firstNonEmpty(entities[i+1]);
				if (pparen
				 && *pparen !is entities[i+1]
				 && pparen.token == tokenLookup!"(")
				{
					auto paren = *pparen;
					*pparen = new Entity();
					entities = entities[0..i] ~ group([entities[i], paren]) ~ entities[i+1..$];
					continue;
				}
			}

			i++;
		}

		foreach (e; entities)
			postProcessParens(e.children);
	}

	static bool isValidIdentifier(string s)
	{
		if (!s.length)
			return false;
		if (!isAlpha(s[0]))
			return false;
		foreach (c; s[1..$])
			if (!isAlphaNum(c))
				return false;
		return true;
	}

	/// Get all nodes between (exclusively) two addresses.
	/// If either address is empty, then the respective bound is the respective extreme.
	static Entity[] nodesBetween(Entity root, size_t[] a, size_t[] b)
	{
		while (a.length && b.length && a[0] == b[0])
		{
			root = root.children[a[0]];
			a = a[1..$];
			b = b[1..$];
		}
		size_t index0, index1;
		Entity[] children0, children1;
		if (a.length)
		{
			index0 = a[0] + 1;
			if (a.length > 1)
				children0 = nodesBetween(root.children[a[0]], a[1..$], null);
		}
		else
			index0 = 0;

		if (b.length)
		{
			index1 = b[0];
			if (b.length > 1)
				children1 = nodesBetween(root.children[b[0]], null, b[1..$]);
		}
		else
			index1 = root.children.length;

		assert(index0 <= index1);
		return children0 ~ root.children[index0 .. index1] ~ children1;
	}

	static void postProcessRecursive(ref Entity[] entities)
	{
		foreach (e; entities)
			if (e.children.length)
				postProcessRecursive(e.children);

		postProcessSimplify(entities);
		postProcessImports(entities);
		postProcessTemplates(entities);
		postProcessDependency(entities);
		postProcessBlockKeywords(entities);
		postProcessDependencyBlock(entities);
		postProcessBlockStatements(entities);
		postProcessPairs(entities);
		postProcessParens(entities);
	}

	/// Attempt to link together function arguments / parameters for
	/// things that look like calls to the same function, to allow removing
	/// unused function arguments / parameters.
	static void postProcessArgs(ref Entity[] entities)
	{
		string lastID;

		Entity[][][string] calls;

		void visit(Entity entity)
		{
			auto id = entity.head.strip();
			if (entity.token == Token.other && isValidIdentifier(id) && !entity.tail && !entity.children)
				lastID = id;
			else
			if (lastID && entity.token == tokenLookup!"(")
			{
				size_t[] stack;
				struct Comma { size_t[] addr, after; }
				Comma[] commas;

				bool afterComma;

				// Find all top-level commas
				void visit2(size_t i, Entity entity)
				{
					stack ~= i;
					if (afterComma)
					{
						commas[$-1].after = stack;
						//entity.comments ~= "After-comma %d".format(commas.length);
						afterComma = false;
					}

					if (entity.token == tokenLookup!",")
					{
						commas ~= Comma(stack);
						//entity.comments ~= "Comma %d".format(commas.length);
						afterComma = true;
					}
					else
					if (entity.head.length || entity.tail.length)
						{}
					else
						foreach (j, child; entity.children)
							visit2(j, child);
					stack = stack[0..$-1];
				}

				foreach (i, child; entity.children)
					visit2(i, child);

				// Find all nodes between commas, effectively obtaining the arguments
				size_t[] last = null;
				commas ~= [Comma()];
				Entity[][] args;
				foreach (i, comma; commas)
				{
					//Entity entityAt(Entity root, size_t[] address) { return address.length ? entityAt(root.children[address[0]], address[1..$]) : root; }
					//entityAt(entity, last).comments ~= "nodesBetween-left %d".format(i);
					//entityAt(entity, comma.after).comments ~= "nodesBetween-right %d".format(i);
					args ~= nodesBetween(entity, last, comma.after);
					last = comma.addr;
				}

				// Register the arguments
				foreach (i, arg; args)
				{
					debug
						foreach (j, e; arg)
							e.comments ~= "%s arg %d node %d".format(lastID, i, j);

					if (arg.length == 1)
					{
						if (lastID !in calls)
							calls[lastID] = null;
						while (calls[lastID].length < i+1)
							calls[lastID] ~= null;
						calls[lastID][i] ~= arg[0];
					}
				}

				lastID = null;
				return;
			}
			else
			if (entity.token == tokenLookup!"!")
				{}
			else
			if (entity.head || entity.tail)
				lastID = null;

			foreach (child; entity.children)
				visit(child);
		}

		foreach (entity; entities)
			visit(entity);

		// For each parameter, create a dummy empty node which is a dependency for all of the arguments.
		auto callRoot = new Entity();
		debug callRoot.comments ~= "Args root";
		entities ~= callRoot;

		foreach (id; calls.keys.sort())
		{
			auto funRoot = new Entity();
			debug funRoot.comments ~= "%s root".format(id);
			callRoot.children ~= funRoot;

			foreach (i, args; calls[id])
			{
				auto e = new Entity();
				debug e.comments ~= "%s param %d".format(id, i);
				funRoot.children ~= e;
				foreach (arg; args)
					e.dependents ~= EntityRef(arg);
			}
		}
	}

	static void postProcess(ref Entity[] entities)
	{
		postProcessRecursive(entities);
		postProcessArgs(entities);
	}

	static Entity* firstNonEmpty(ref return Entity e)
	{
		if (e.head.length)
			return &e;
		foreach (ref c; e.children)
		{
			auto r = firstNonEmpty(c);
			if (r)
				return r;
		}
		if (e.tail.length)
			return &e;
		return null;
	}

	static Token firstToken(Entity e)
	{
		while (!e.token && e.children.length)
			e = e.children[0];
		return e.token;
	}
}

public:

/// Split the text into sequences for each fun is always true, and then always false
Entity[] parseSplit(alias fun)(string text)
{
	Entity[] result;
	size_t i, wordStart, wordEnd;
	for (i = 1; i <= text.length; i++)
		if (i==text.length || (fun(text[i-1]) && !fun(text[i])))
		{
			if (wordStart != i)
				result ~= new Entity(text[wordStart..wordEnd], null, text[wordEnd..i]);
			wordStart = wordEnd = i;
		}
		else
		if ((!fun(text[i-1]) && fun(text[i])))
			wordEnd = i;
	return result;
}

alias parseToWords = parseSplit!isNotAlphaNum;
alias parseToLines = parseSplit!isNewline;
alias parseToNull  = parseSplit!(c => c == '\0');

/// Split s on end~start, preserving end and start on each chunk
private string[] split2(string end, string start)(string s)
{
	enum sep = end ~ start;
	return split2Impl(s, sep, end.length);
}

private string[] split2Impl(string s, string sep, size_t endLength)
{
	string[] result;
	while (true)
	{
		auto i = s.indexOf(sep);
		if (i < 0)
			return result ~ s;
		i += endLength;
		result ~= s[0..i];
		s = s[i..$];
	}
}

unittest
{
	assert(split2!("]", "[")(null) == [""]);
	assert(split2!("]", "[")("[foo]") == ["[foo]"]);
	assert(split2!("]", "[")("[foo][bar]") == ["[foo]", "[bar]"]);
	assert(split2!("]", "[")("[foo] [bar]") == ["[foo] [bar]"]);
}

// From ae.utils.array
template skipWhile(alias pred)
{
	T[] skipWhile(T)(ref T[] source, bool orUntilEnd = false)
	{
		enum bool isSlice = is(typeof(pred(source[0..1])));
		enum bool isElem  = is(typeof(pred(source[0]   )));
		static assert(isSlice || isElem, "Can't skip " ~ T.stringof ~ " until " ~ pred.stringof);
		static assert(isSlice != isElem, "Ambiguous types for skipWhile: " ~ T.stringof ~ " and " ~ pred.stringof);

		foreach (i; 0 .. source.length)
		{
			bool match;
			static if (isSlice)
				match = pred(source[i .. $]);
			else
				match = pred(source[i]);
			if (!match)
			{
				auto result = source[0..i];
				source = source[i .. $];
				return result;
			}
		}

		if (orUntilEnd)
		{
			auto result = source;
			source = null;
			return result;
		}
		else
			return null;
	}
}

Entity[] parseDiff(string s)
{
	auto entities = s
		.split2!("\n", "diff ")
		.map!(
			(string file)
			{
				auto chunks = file.split2!("\n", "@@ ");
				return new Entity(chunks[0], chunks[1..$].map!(chunk => new Entity(chunk)).array);
			}
		)
		.array
	;

	// If a word occurs only in two or more (but not all) hunks,
	// create dependency nodes which make Dustmite try reducing these
	// hunks simultaneously.
	{
		auto allHunks = entities.map!(entity => entity.children).join;
		auto hunkWords = allHunks
			.map!(hunk => hunk.head)
			.map!((text) {
				bool[string] words;
				while (text.length)
				{
					alias isWordChar = c => isAlphaNum(c) || c == '_';
					text.skipWhile!(not!isWordChar)(true);
					auto word = text.skipWhile!isWordChar(true);
					if (word.length)
						words[word] = true;
				}
				return words;
			})
			.array;

		auto allWords = hunkWords
			.map!(words => words.byPair)
			.joiner
			.assocArray;
		string[bool[]] sets; // Deduplicated sets of hunks to try to remove at once
		foreach (word; allWords.byKey)
		{
			immutable bool[] hunkHasWord = hunkWords.map!(c => !!(word in c)).array.assumeUnique;
			auto numHunksWithWord = hunkHasWord.count!(b => b);
			if (numHunksWithWord > 1 && numHunksWithWord < allHunks.length)
				sets[hunkHasWord] = word;
		}

		foreach (set, word; sets)
		{
			auto e = new Entity();
			debug e.comments ~= word;
			e.dependents ~= allHunks.length.iota
				.filter!(i => set[i])
				.map!(i => EntityRef(allHunks[i]))
				.array;
			entities ~= e;
		}
	}

	return entities;
}

size_t getIndent(string line, uint tabWidth, size_t lastIndent)
{
	size_t indent = 0;
charLoop:
	foreach (c; line)
		switch (c)
		{
			case ' ':
				indent++;
				break;
			case '\t':
				indent += tabWidth;
				break;
			case '\r':
			case '\n':
				// Treat empty (whitespace-only) lines as belonging to the
				// immediately higher (most-nested) block.
				indent = lastIndent;
				break charLoop;
			default:
				break charLoop;
		}
	return indent;
}

Entity[] parseIndent(string s, uint tabWidth)
{
	Entity[] root;
	Entity[] stack;

	foreach (line; s.split2!("\n", ""))
	{
		auto indent = getIndent(line, tabWidth, stack.length);
		auto e = new Entity(line);
		foreach_reverse (i; 0 .. min(indent, stack.length)) // non-inclusively up to indent
			if (stack[i])
			{
				stack[i].children ~= e;
				goto parentFound;
			}
		root ~= e;
	parentFound:
		stack.length = indent + 1;
		stack[indent] = new Entity;
		e.children ~= stack[indent];
	}

	return root;
}

Entity[] parseLisp(string s)
{
	// leaf head: token (non-whitespace)
	// leaf tail: whitespace
	// non-leaf head: "(" and any whitespace
	// non-leaf tail: ")" and any whitespace

	size_t i;

	size_t last;
	scope(success) assert(last == s.length, "Incomplete slice");
	string slice(void delegate() advance)
	{
		assert(last == i, "Non-contiguous slices");
		auto start = i;
		advance();
		last = i;
		return s[start .. i];
	}

	/// How many characters did `advance` move forward by?
	size_t countAdvance(void delegate() advance)
	{
		auto start = i;
		advance();
		return i - start;
	}

	void advanceWhitespace()
	{
		while (i < s.length)
		{
			switch (s[i])
			{
				case ' ':
				case '\t':
				case '\r':
				case '\n':
				case '\f':
				case '\v':
					i++;
					continue;

				case ';':
					i++;
					while (i < s.length && s[i] != '\n')
						i++;
					continue;

				default:
					return; // stop
			}
			assert(false); // unreachable
		}
	}

	void advanceToken()
	{
		assert(countAdvance(&advanceWhitespace) == 0);
		assert(i < s.length);

		switch (s[i])
		{
			case '(':
			case ')':
			case '[':
			case ']':
				assert(false);
			case '"':
				i++;
				while (i < s.length)
				{
					switch (s[i])
					{
						case '"':
							i++;
							return; // stop

						case '\\':
							i++;
							if (i < s.length)
								i++;
							continue;

						default:
							i++;
							continue;
					}
					assert(false); // unreachable
				}
				break;
			default:
				while (i < s.length)
				{
					switch (s[i])
					{
						case ' ':
						case '\t':
						case '\r':
						case '\n':
						case '\f':
						case '\v':
						case ';':

						case '"':
						case '(':
						case ')':
						case '[':
						case ']':
							return; // stop

						case '\\':
							i++;
							if (i < s.length)
								i++;
							continue;

						default:
							i++;
							continue;
					}
					assert(false); // unreachable
				}
				break;
		}
	}

	void advanceParen(char paren)
	{
		assert(i < s.length && s[i] == paren);
		i++;
		advanceWhitespace();
	}

	Entity[] parse(bool topLevel)
	{
		Entity[] result;
		if (topLevel) // Handle reading whitespace at top-level
		{
			auto ws = slice(&advanceWhitespace);
			if (ws.length)
				result ~= new Entity(ws);
		}

		Entity parseParen(char open, char close)
		{
			auto entity = new Entity(slice({ advanceParen(open); }));
			entity.children = parse(false);
			if (i < s.length)
				entity.tail = slice({ advanceParen(close); });
			return entity;
		}

		while (i < s.length)
		{
			switch (s[i])
			{
				case '(':
					result ~= parseParen('(', ')');
					continue;
				case '[':
					result ~= parseParen('[', ']');
					continue;

				case ')':
				case ']':
					if (!topLevel)
						break;
					result ~= new Entity(slice({ advanceParen(s[i]); }));
					continue;

				default:
					result ~= new Entity(
						slice(&advanceToken),
						null,
						slice(&advanceWhitespace),
					);
					continue;
			}
			break;
		}
		return result;
	}

	return parse(true);
}

private:

Entity loadJson(string contents)
{
	import std.json : JSONValue, parseJSON;

	auto jsonDoc = parseJSON(contents);
	enforce(jsonDoc["version"].integer == 1, "Unknown JSON version");

	// Pass 1: calculate the total size of all data.
	// --no-remove and some optimizations require that entity strings
	// are arranged in contiguous memory.
	size_t totalSize;
	void scanSize(ref JSONValue v)
	{
		if (auto p = "head" in v.object)
			totalSize += p.str.length;
		if (auto p = "children" in v.object)
			p.array.each!scanSize();
		if (auto p = "tail" in v.object)
			totalSize += p.str.length;
	}
	scanSize(jsonDoc["root"]);

	auto buf = new char[totalSize];
	size_t pos = 0;

	Entity[string] labeledEntities;
	JSONValue[][Entity] entityDependents;

	// Pass 2: Create the entity tree
	Entity parse(ref JSONValue v)
	{
		auto e = new Entity;

		if (auto p = "filename" in v.object)
		{
			e.file = new Entity.FileProperties;
			e.file.name = p.str.buildNormalizedPath;
			enforce(e.file.name.length &&
				!e.file.name.isAbsolute &&
				!e.file.name.pathSplitter.canFind(`..`),
				"Invalid filename in JSON file: " ~ p.str);
		}

		if (auto p = "head" in v.object)
		{
			auto end = pos + p.str.length;
			buf[pos .. end] = p.str;
			e.head = buf[pos .. end].assumeUnique;
			pos = end;
		}
		if (auto p = "children" in v.object)
			e.children = p.array.map!parse.array;
		if (auto p = "tail" in v.object)
		{
			auto end = pos + p.str.length;
			buf[pos .. end] = p.str;
			e.tail = buf[pos .. end].assumeUnique;
			pos = end;
		}

		if (auto p = "noRemove" in v.object)
			e.noRemove = (){
				if (*p == JSONValue(true)) return true;
				if (*p == JSONValue(false)) return false;
				throw new Exception("noRemove is not a boolean");
			}();

		if (auto p = "label" in v.object)
		{
			enforce(p.str !in labeledEntities, "Duplicate label in JSON file: " ~ p.str);
			labeledEntities[p.str] = e;
		}
		if (auto p = "dependents" in v.object)
			entityDependents[e] = p.array;

		return e;
	}
	auto root = parse(jsonDoc["root"]);

	// Pass 3: Resolve dependents
	foreach (e, dependents; entityDependents)
		e.dependents = dependents
			.map!((ref d) => labeledEntities
				.get(d.str, null)
				.enforce("Unknown label in dependents: " ~ d.str)
				.EntityRef
			)
			.array;

	return root;
}

bool isNewline(char c) { return c == '\r' || c == '\n'; }
alias isNotAlphaNum = not!isAlphaNum;

// https://d.puremagic.com/issues/show_bug.cgi?id=11824
auto arrayMap(alias fun, T)(T[] arr)
{
	alias R = typeof(fun(arr[0]));
	auto result = new R[arr.length];
	foreach (i, v; arr)
		result[i] = fun(v);
	return result;
}
