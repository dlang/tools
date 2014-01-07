/// Very simplistic D source code "parser"
/// Written by Vladimir Panteleev <vladimir@thecybershadow.net>
/// Released into the Public Domain

module dsplit;

import std.ascii;
import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.string;
debug import std.stdio;

class Entity
{
	string head;
	Entity[] children;
	string tail;

	string filename, contents;
	@property bool isFile() { return filename != ""; }

	bool isPair;           /// internal hint
	bool noRemove;         /// don't try removing this entity (children OK)

	bool removed;          /// For dangling dependencies
	Entity[] dependencies;

	int id;                /// For diagnostics
	size_t descendants;    /// For progress display

	this(string head = null, Entity[] children = null, string tail = null, string filename = null, bool isPair = false)
	{
		this.head     = head;
		this.children = children;
		this.tail     = tail;
		this.filename = filename;
		this.isPair   = isPair;
	}
}

struct ParseOptions
{
	enum Mode { Source, Words }

	bool stripComments;
	Mode mode;
}

Entity loadFiles(ref string path, ParseOptions options)
{
	if (isFile(path))
	{
		auto filePath = path;
		path = stripExtension(path);
		return loadFile(baseName(filePath).replace(`\`, `/`), filePath, options);
	}
	else
	{
		auto set = new Entity();
		foreach (string entry; dirEntries(path, SpanMode.breadth))
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
		set.replaceInPlace(start, end, [new Entity(null, set[start..end].dup, null)]);
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

const DExtensions = [".d", ".di"];

Entity loadFile(string name, string path, ParseOptions options)
{
	debug writeln("Loading ", path);
	auto result = new Entity();
	result.filename = name.replace(`\`, `/`);
	result.contents = cast(string)read(path);

	if (options.stripComments)
		if (DExtensions.canFind(path.extension.toLower))
			result.contents = stripDComments(result.contents);

	final switch (options.mode)
	{
	case ParseOptions.Mode.Source:
		if (DExtensions.canFind(path.extension.toLower) && !result.contents.startsWith("Ddoc"))
			result.children = parseD(result.contents);
		else
		// One could add custom splitters for other languages here - for example, a simple line/word/character splitter for most text-based formats
			result.children = [new Entity(result.contents, null, null)];
		break;
	case ParseOptions.Mode.Words:
		result.children = parseToWords(result.contents);
		break;
	}
	return result;
}

class EndOfInput : Throwable { this() { super(null); } }
void lchop(ref string r, size_t n = 1)
{
	if (r.length < n)
		throw new EndOfInput;
	r = r[n..$];
}

string skipSymbol(string s, ref size_t i)
{
	auto r = s[i..$];

	try
		switch (r[0])
		{
		case '\'':
			r.lchop();
			if (r.startsWith('\\'))
				r.lchop(2);
			while (!r.startsWith('\''))
				r.lchop();
			r.lchop();
			break;
		case '\\':
			r.lchop(2);
			break;
		case '"':
			r.lchop();
			while (!r.startsWith('"'))
			{
				if (r.startsWith('\\'))
					r.lchop(2);
				else
					r.lchop();
			}
			r.lchop();
			break;
		case 'r':
			if (r.startsWith(`r"`))
			{
				r.lchop(2);
				while (!r.startsWith('"'))
					r.lchop();
				r.lchop();
				break;
			}
			else
				goto default;
		case '`':
			r.lchop();
			while (!r.startsWith('`'))
				r.lchop();
			r.lchop();
			break;
		case '/':
			r.lchop();
			if (r.startsWith('/'))
			{
				while (!r.startsWith('\r') && !r.startsWith('\n'))
					r.lchop();
			}
			else
			if (r.startsWith('*'))
			{
				r.lchop();
				while (!r.startsWith("*/"))
					r.lchop();
				r.lchop(2);
			}
			else
			if (r.startsWith('+'))
			{
				r.lchop();
				int commentLevel = 1;
				while (commentLevel)
				{
					if (r.startsWith("/+"))
						commentLevel++, r.lchop(2);
					else
					if (r.startsWith("+/"))
						commentLevel--, r.lchop(2);
					else
						r.lchop();
				}
			}
			else
				r.lchop();
			break;
		default:
			r.lchop();
			break;
		}
	catch (EndOfInput)
		r = null;

	auto len = s.length - i - r.length;
	i += len;
	return s[i-len..i];
}

/// Moves i forward over first series of EOL characters, or until first non-whitespace character
void skipToEOL(string s, ref size_t i)
{
	while (i < s.length)
	{
		if (s[i] == '\r' || s[i] == '\n')
		{
			while (i < s.length && (s[i] == '\r' || s[i] == '\n'))
				i++;
			return;
		}
		else
		if (isWhite(s[i]))
			i++;
		else
		if (s[i..$].startsWith("//"))
			skipSymbol(s, i);
		else
			break;
	}
}

/// Moves i backwards to the beginning of the current line, but not any further than start
void backToEOL(string s, ref size_t i, size_t start)
{
	while (i>start && isWhite(s[i-1]) && s[i-1] != '\n')
		i--;
}

Entity[] parseD(string s)
{
	size_t i = 0;
	size_t start;
	string innerTail;

	Entity[] parseScope(char end)
	{
		// Here be dragons.

		enum MAX_SPLITTER_LEVELS = 6;
		struct DSplitter { char open, close, sep; }
		static const DSplitter[MAX_SPLITTER_LEVELS] splitters = [{'#','\n'}, {'{','}',';'}, {'(',')'}, {'[',']'}, {sep:','}, {sep:' '}];

		Entity[][MAX_SPLITTER_LEVELS] splitterQueue;

		Entity[] terminateLevel(int level)
		{
			if (level == MAX_SPLITTER_LEVELS)
			{
				auto text = s[start..i];
				start = i;
				return splitText(text);
			}
			else
			{
				auto next = terminateLevel(level+1);
				if (next.length <= 1)
					splitterQueue[level] ~= next;
				else
					splitterQueue[level] ~= new Entity(null, next, null);
				auto r = splitterQueue[level];
				splitterQueue[level] = null;
				return r;
			}
		}

		string terminateText()
		{
			auto r = s[start..i];
			start = i;
			return r;
		}

		characterLoop:
		while (i < s.length)
		{
			char c = s[i];
			foreach (int level, info; splitters)
				if (info.sep && c == info.sep)
				{
					auto children = terminateLevel(level+1);
					assert(i == start);
					i++; skipToEOL(s, i);
					splitterQueue[level] ~= new Entity(null, children, terminateText());
					continue characterLoop;
				}
				else
				if (info.open && c == info.open)
				{
					auto openPos = i;
					backToEOL(s, i, start);
					auto pairHead = terminateLevel(level+1);

					i = openPos+1; skipToEOL(s, i);
					auto startSequence = terminateText();
					auto bodyContents = parseScope(info.close);

					auto pairBody = new Entity(startSequence, bodyContents, innerTail);

					if (pairHead.length == 0)
						splitterQueue[level] ~= pairBody;
					else
					if (pairHead.length == 1)
						splitterQueue[level] ~= new Entity(null, pairHead ~ pairBody, null, null, true);
					else
						splitterQueue[level] ~= new Entity(null, [new Entity(null, pairHead, null), pairBody], null, null, true);
					continue characterLoop;
				}

			if (end && c == end)
			{
				auto closePos = i;
				backToEOL(s, i, start);
				auto result = terminateLevel(0);
				i = closePos+1; skipToEOL(s, i);
				innerTail = terminateText();
				return result;
			}
			else
				skipSymbol(s, i);
		}

		innerTail = null;
		return terminateLevel(0);
	}

	auto result = parseScope(0);
	postProcessD(result);
	return result;
}

string stripDComments(string s)
{
	auto result = appender!string();
	size_t i = 0;
	while (i < s.length)
	{
		auto sym = skipSymbol(s, i);
		if (!sym.startsWithComment())
			result.put(sym);
	}
	return result.data;
}

void postProcessD(ref Entity[] entities, int depth=0)
{
	for (int i=0; i<entities.length;)
	{
		// Process comma-separated lists. Nest later items and add a dependency for the comma.

		if (i+2 <= entities.length && entities[i].children.length >= 1 && entities[i].tail.stripD() == "," && depth < 100)
		{
			// Put the comma in its own entity, so it can have a dependency
			auto comma = new Entity(entities[i].tail);
			entities[i].tail = null;

			// Create a separate group for the item and its following comma, so that they could be removed together
			auto commaGroup = new Entity(null, [entities[i].children[$-1], comma], null);
			entities[i].children[$-1] = commaGroup;

			// Place all the remaining items from the current entity into their own new group,
			// so that they could be removed together and the comma could have a dependency on all the remaining items
			auto rest = new Entity(null, entities[i+1..$], null);
			entities[i].children ~= rest;
			entities = entities[0..i+1];

			// Register the dependency
			comma.dependencies ~= rest;
		}

		// Group together consecutive entities which might represent a single language construct
		// There is no penalty for false positives, so accuracy is not very important

		if (i+2 <= entities.length && entities.length > 2 && (
		    (getHeadText(entities[i]).startsWithWord("do") && getHeadText(entities[i+1]).isWord("while"))
		 || (getHeadText(entities[i]).startsWithWord("try") && getHeadText(entities[i+1]).startsWithWord("catch"))
		 || (getHeadText(entities[i]).startsWithWord("try") && getHeadText(entities[i+1]).startsWithWord("finally"))
		 || (getHeadText(entities[i+1]).isWord("in"))
		 || (getHeadText(entities[i+1]).isWord("out"))
		 || (getHeadText(entities[i+1]).isWord("body"))
		))
		{
			entities.replaceInPlace(i, i+2, [new Entity(null, entities[i..i+2].dup, null)]);
			continue;
		}

		postProcessD(entities[i].children, depth+1);
		i++;
	}
}

const bool[string] wordsToSplit;
static this() { wordsToSplit = ["else":true]; }

Entity[] splitText(string s)
{
	Entity[] result;
	while (s.length)
	{
		auto word = firstWord(s);
		if (word in wordsToSplit)
		{
			size_t p = word.ptr + word.length - s.ptr;
			skipToEOL(s, p);
			result ~= new Entity(s[0..p], null, null);
			s = s[p..$];
		}
		else
		{
			result ~= new Entity(s, null, null);
			s = null;
		}
	}

	return result;
}

string stripD(string s)
{
	size_t i=0;
	size_t start=s.length, end=s.length;
	while (i < s.length)
	{
		if (s[i..$].startsWithComment())
			skipSymbol(s, i);
		else
		if (!isWhite(s[i]))
		{
			if (start > i)
				start = i;
			skipSymbol(s, i);
			end = i;
		}
		else
			i++;
	}
	return s[start..end];
}

string firstWord(string s)
{
	size_t i = 0;
	s = stripD(s);
	while (i<s.length && !isWhite(s[i]))
		i++;
	return s[0..i];
}

bool startsWithWord(string s, string word)
{
	s = stripD(s);
	return s.startsWith(word) && (s.length == word.length || !isAlphaNum(s[word.length]));
}

bool endsWithWord(string s, string word)
{
	s = stripD(s);
	return s.endsWith(word) && (s.length == word.length || !isAlphaNum(s[$-word.length-1]));
}

bool isWord(string s, string word)
{
	return stripD(s) == word;
}

bool startsWithComment(string s)
{
	return s.startsWith("//") || s.startsWith("/*") || s.startsWith("/+");
}

Entity getHeadEntity(Entity e)
{
	if (e.head.length)
		return e;
	foreach (child; e.children)
	{
		Entity r = getHeadEntity(child);
		if (r)
			return r;
	}
	if (e.tail.length)
		return e;
	return null;
}

string getHeadText(Entity e)
{
	e = getHeadEntity(e);
	if (!e)
		return null;
	if (e.head)
		return e.head;
	return e.tail;
}

// ParseOptions.Mode.Words

bool isDWordChar(char c)
{
	return isAlphaNum(c) || c=='_' || c=='@';
}

public Entity[] parseToWords(string text)
{
	Entity[] result;
	size_t i, wordStart, wordEnd;
	for (i = 1; i <= text.length; i++)
		if (i==text.length || (!isDWordChar(text[i-1]) && isDWordChar(text[i])))
		{
			if (wordStart != i)
				result ~= new Entity(text[wordStart..wordEnd], null, text[wordEnd..i]);
			wordStart = wordEnd = i;
		}
		else
		if ((isDWordChar(text[i-1]) && !isDWordChar(text[i])))
			wordEnd = i;
	return result;
}
