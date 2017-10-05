/// Simple source code splitter
/// Written by Vladimir Panteleev <vladimir@thecybershadow.net>
/// Released into the Public Domain

module splitter;

import std.ascii;
import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.functional;
import std.path;
import std.range;
import std.string;
import std.traits;
import std.stdio : stderr;

/// Represents a slice of the original code.
class Entity
{
	string head;           /// This node's "head", e.g. "{" for a statement block.
	Entity[] children;     /// This node's children nodes, e.g. the statements of the statement block.
	string tail;           /// This node's "tail", e.g. "}" for a statement block.

	string filename, contents;
	@property bool isFile() { return filename != ""; }

	bool isPair;           /// Internal hint for --dump output
	bool noRemove;         /// Don't try removing this entity (children OK)

	bool removed;          /// For dangling dependencies
	Entity[] dependencies; /// If any of these entities are omitted, so should this entity.

	int id;                /// For diagnostics
	size_t descendants;    /// For progress display

	DSplitter.Token token; /// Used internally

	this(string head = null, Entity[] children = null, string tail = null)
	{
		this.head     = head;
		this.children = children;
		this.tail     = tail;
	}

	string[] comments;

	@property string comment()
	{
		string[] result = comments;
		if (isPair)
		{
			assert(token == DSplitter.Token.none);
			result ~= "Pair";
		}
		if (token && DSplitter.tokenText[token])
			result ~= DSplitter.tokenText[token];
		return result.length ? result.join(" / ") : null;
	}

	override string toString()
	{
		return "%(%s%) %s %(%s%)".format([head], children, [tail]);
	}
}

enum Mode
{
	source,
	words,     /// split identifiers, for obfuscation
}

enum Splitter
{
	files,     /// Load entire files only
	lines,     /// Split by line ends
	words,     /// Split by whitespace
	D,         /// Parse D source code
	diff,      /// Unified diffs
}
immutable string[] splitterNames = [EnumMembers!Splitter].map!(e => e.text().toLower()).array();

struct ParseRule
{
	string pattern;
	Splitter splitter;
}

struct ParseOptions
{
	enum Mode { source, words }

	bool stripComments;
	ParseRule[] rules;
	Mode mode;
}

/// Parse the given file/directory.
/// For files, modifies path to be the base name for .test / .reduced directories.
Entity loadFiles(ref string path, ParseOptions options)
{
	if (isFile(path))
	{
		auto filePath = path;
		path = stripExtension(path);
		return loadFile(filePath.baseName(), filePath, options);
	}
	else
	{
		auto set = new Entity();
		foreach (string entry; dirEntries(path, SpanMode.breadth).array.sort!((a, b) => a.name < b.name))
			if (isFile(entry))
			{
				assert(entry.startsWith(path));
				auto name = entry[path.length+1..$];
				set.children ~= loadFile(name, entry, options);
			}
		return set;
	}
}

enum BIN_SIZE = 2;

void optimize(Entity set)
{
	static void group(ref Entity[] set, size_t start, size_t end)
	{
		//set = set[0..start] ~ [new Entity(removable, set[start..end])] ~ set[end..$];
		auto children = set[start..end].dup;
		auto e = new Entity(null, children, null);
		e.noRemove = children.any!(c => c.noRemove)();
		set.replaceInPlace(start, end, [e]);
	}

	static void clusterBy(ref Entity[] set, size_t binSize)
	{
		while (set.length > binSize)
		{
			auto size = set.length >= binSize*2 ? binSize : (set.length+1) / 2;
			//auto size = binSize;

			auto bins = set.length/size;
			if (set.length % size > 1)
				group(set, bins*size, set.length);
			foreach_reverse (i; 0..bins)
				group(set, i*size, (i+1)*size);
		}
	}

	static void doOptimize(Entity e)
	{
		foreach (c; e.children)
			doOptimize(c);
		clusterBy(e.children, BIN_SIZE);
	}

	doOptimize(set);
}

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
	{ "*"      , Splitter.files },
];

Entity loadFile(string name, string path, ParseOptions options)
{
	stderr.writeln("Loading ", path);
	auto result = new Entity();
	result.filename = name.replace(`\`, `/`);
	result.contents = cast(string)read(path);

	auto base = name.baseName();
	foreach (rule; chain(options.rules, defaultRules))
		if (base.globMatch(rule.pattern))
		{
			final switch (rule.splitter)
			{
				case Splitter.files:
					result.children = [new Entity(result.contents, null, null)];
					return result;
				case Splitter.lines:
					result.children = parseToLines(result.contents);
					return result;
				case Splitter.words:
					result.children = parseToWords(result.contents);
					return result;
				case Splitter.D:
				{
					if (result.contents.startsWith("Ddoc"))
						goto case Splitter.files;

					DSplitter splitter;
					if (options.stripComments)
						result.contents = splitter.stripComments(result.contents);

					final switch (options.mode)
					{
						case ParseOptions.Mode.source:
							result.children = splitter.parse(result.contents);
							return result;
						case ParseOptions.Mode.words:
							result.children = splitter.parseToWords(result.contents);
							return result;
					}
				}
				case Splitter.diff:
					result.children = parseDiff(result.contents);
					return result;
			}
		}
	assert(false); // default * rule should match everything
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

		max = generated0 + tokenLookup.length
	}

	enum Token[string] tokenLookup = // DMD pr/2824
	{
		Token[string] lookup;

		auto t = Token.generated0;
		Token add(string s)
		{
			auto p = s in lookup;
			if (p)
				return *p;
			return lookup[s] = t++;
		}

		foreach (pair; pairs)
		{
			add(pair.start);
			add(pair.end  );
		}

		foreach (i, synonyms; separators)
			foreach (sep; synonyms)
				add(sep);

		return lookup;
	}();

	static immutable string[Token.max] tokenText =
	{
		string[Token.max] result;
		foreach (k, v; tokenLookup)
			result[v] = k;
		return result;
	}();

	struct TokenPair { Token start, end; }
	static Token lookupToken(string s) { return tokenLookup[s]; }
	static TokenPair makeTokenPair(Pair pair) { return TokenPair(tokenLookup[pair.start], tokenLookup[pair.end]); }
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
			case tokenLookup[";"]:
				return SeparatorType.postfix;
			case tokenLookup["import"]:
				return SeparatorType.prefix;
			case tokenLookup["else"]:
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
				if (consume(`r"`))
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

		tokenLoop:
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
			if (e.head.empty && e.tail.empty && e.dependencies.empty)
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
			e.dependencies ~= tail;
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
			if (e.token == tokenLookup["!"] && entities[i+1].children.length && entities[i+1].children[0].token == tokenLookup["("])
			{
				auto dependency = new Entity;
				e.dependencies ~= dependency;
				entities[i+1].children[0].dependencies ~= dependency;
				entities = entities[0..i+1] ~ dependency ~ entities[i+1..$];
			}
	}

	static void postProcessDependencyBlock(ref Entity[] entities)
	{
		foreach (i, e; entities)
			if (i && !e.token && e.children.length && getSeparatorType(e.children[0].token) == SeparatorType.binary && !e.children[0].children)
				e.children[0].dependencies ~= entities[i-1];
	}

	static void postProcessBlockKeywords(ref Entity[] entities)
	{
		for (size_t i=0; i<entities.length;)
		{
			if (blockKeywordTokens.canFind(entities[i].token) && i+1 < entities.length)
			{
				auto j = i + 1;
				if (j < entities.length && entities[j].token == tokenLookup["("])
					j++;
				j++; // ; or {
				if (j <= entities.length)
				{
					entities = entities[0..i] ~ group(group(entities[i..j-1]) ~ entities[j-1..j]) ~ entities[j..$];
					continue;
				}
			}

			i++;
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
			
			if (consume(tokenLookup["if"]) || consume(tokenLookup["static if"]))
				consume(tokenLookup["else"]);
			else
			if (consume(tokenLookup["do"]))
				consume(tokenLookup["while"]);
			else
			if (consume(tokenLookup["try"]))
			{
				while (consume(tokenLookup["catch"]))
					continue;
				consume(tokenLookup["finally"]);
			}

			if (i == j)
			{
				j++;
				while (consume(tokenLookup["in"]) || consume(tokenLookup["out"]) || consume(tokenLookup["body"]))
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

			if (entities[i].token == tokenLookup["{"])
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
			if (entities[i].token == tokenLookup[";"])
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
				auto pparen = firstHead(entities[i+1]);
				if (pparen
				 && *pparen !is entities[i+1]
				 && pparen.token == tokenLookup["("])
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
			if (lastID && entity.token == tokenLookup["("])
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

					if (entity.token == tokenLookup[","])
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
			if (entity.token == tokenLookup["!"])
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

		foreach (id, params; calls)
		{
			auto funRoot = new Entity();
			debug funRoot.comments ~= "%s root".format(id);
			callRoot.children ~= funRoot;

			foreach (i, args; params)
			{
				auto e = new Entity();
				debug e.comments ~= "%s param %d".format(id, i);
				funRoot.children ~= e;
				foreach (arg; args)
					arg.dependencies ~= e;
			}
		}
	}

	static void postProcess(ref Entity[] entities)
	{
		postProcessRecursive(entities);
		postProcessArgs(entities);
	}

	static Entity* firstHead(ref Entity e)
	{
		if (e.head.length)
			return &e;
		foreach (ref c; e.children)
		{
			auto r = firstHead(c);
			if (r)
				return r;
		}
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

Entity[] parseDiff(string s)
{
	return s
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
}

private:

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
