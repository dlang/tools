/// DustMite, a D test case minimization tool
/// Written by Vladimir Panteleev <vladimir@thecybershadow.net>
/// Released into the Public Domain

module dustmite;

import std.stdio;
import std.file;
import std.path;
import std.string;
import std.getopt;
import std.array;
import std.process;
import std.algorithm;
import std.exception;
import std.datetime;
import std.regex;
import std.conv;
import std.ascii;
import std.random;

import splitter;

alias Splitter = splitter.Splitter;

// Issue 314 workarounds
alias std.string.join join;
alias std.string.startsWith startsWith;

string dir, resultDir, tester, globalCache;
string dirSuffix(string suffix) { return (dir.absolutePath().buildNormalizedPath() ~ "." ~ suffix).relativePath(); }

size_t maxBreadth;
Entity root;
size_t origDescendants;
bool concatPerformed;
int tests; bool foundAnything;
bool noSave, trace, noRedirect;
string strategy = "inbreadth";

struct Times { StopWatch total, load, testSave, resultSave, test, clean, cacheHash, globalCache, misc; }
Times times;
static this() { times.total.start(); times.misc.start(); }
void measure(string what)(void delegate() p)
{
	times.misc.stop(); mixin("times."~what~".start();");
	p();
	mixin("times."~what~".stop();"); times.misc.start();
}

struct Reduction
{
	enum Type { None, Remove, Unwrap, Concat, ReplaceWord }
	Type type;

	// Remove / Unwrap / Concat
	size_t[] address;
	Entity target;

	// ReplaceWord
	string from, to;
	size_t index, total;

	string toString()
	{
		string name = .to!string(type);

		final switch (type)
		{
			case Reduction.Type.None:
				return name;
			case Reduction.Type.ReplaceWord:
				return format(`%s [%d/%d: %s -> %s]`, name, index+1, total, from, to);
			case Reduction.Type.Remove:
			case Reduction.Type.Unwrap:
			case Reduction.Type.Concat:
				string[] segments = new string[address.length];
				Entity e = root;
				size_t progress;
				bool binary = maxBreadth == 2;
				foreach (i, a; address)
				{
					segments[i] = binary ? text(a) : format("%d/%d", e.children.length-a, e.children.length);
					foreach (c; e.children[0..a])
						progress += c.descendants;
					progress++; // account for this node
					e = e.children[a];
				}
				progress += e.descendants;
				return format("[%5.1f%%] %s [%s]", (origDescendants-progress) * 100.0 / origDescendants, name, segments.join(binary ? "" : ", "));
		}
	}
}

auto nullReduction = Reduction(Reduction.Type.None);

int main(string[] args)
{
	bool force, dump, dumpHtml, showTimes, stripComments, obfuscate, keepLength, showHelp, noOptimize;
	string coverageDir;
	string[] reduceOnly, noRemoveStr, splitRules;

	getopt(args,
		"force", &force,
		"reduceonly|reduce-only", &reduceOnly,
		"noremove|no-remove", &noRemoveStr,
		"strip-comments", &stripComments,
		"coverage", &coverageDir,
		"obfuscate", &obfuscate,
		"keep-length", &keepLength,
		"strategy", &strategy,
		"split", &splitRules,
		"dump", &dump,
		"dump-html", &dumpHtml,
		"times", &showTimes,
		"noredirect|no-redirect", &noRedirect,
		"cache", &globalCache, // for research
		"trace", &trace, // for debugging
		"nosave|no-save", &noSave, // for research
		"nooptimize|no-optimize", &noOptimize, // for research
		"h|help", &showHelp
	);

	if (showHelp || args.length == 1 || args.length>3)
	{
		stderr.writef(q"EOS
Usage: %s [OPTION]... PATH TESTER
PATH should be a directory containing a clean copy of the file-set to reduce.
A file path can also be specified. NAME.EXT will be treated like NAME/NAME.EXT.
TESTER should be a shell command which returns 0 for a correct reduction,
and anything else otherwise.
Supported options:
  --force            Force reduction of unusual files
  --reduce-only MASK Only reduce paths glob-matching MASK
                       (may be used multiple times)
  --no-remove REGEXP Do not reduce blocks containing REGEXP
                       (may be used multiple times)
  --strip-comments   Attempt to remove comments from source code.
  --coverage DIR     Load .lst files corresponding to source files from DIR
  --obfuscate        Instead of reducing, obfuscate the input by replacing
                       words with random substitutions
  --keep-length      Preserve word length when obfuscating
  --split MASK:MODE  Parse and reduce files specified by MASK using the given
                       splitter. Can be repeated. MODE must be one of:
                       %-(%s, %)
  --no-redirect      Don't redirect stdout/stderr streams of test command.
EOS", args[0], splitterNames);

		if (!showHelp)
		{
			stderr.write(q"EOS
  --help             Show this message and some less interesting options
EOS");
		}
		else
		{
			stderr.write(q"EOS
  --help             Show this message
Less interesting options:
  --strategy STRAT   Set strategy (careful/lookback/pingpong/indepth/inbreadth)
  --dump             Dump parsed tree to DIR.dump file
  --dump-html        Dump parsed tree to DIR.html file
  --times            Display verbose spent time breakdown
  --cache DIR        Use DIR as persistent disk cache
                       (in addition to memory cache)
  --trace            Save all attempted reductions to DIR.trace
  --no-save          Disable saving in-progress results
  --no-optimize      Disable tree optimization step
                       (may be useful with --dump)
EOS");
		}
		stderr.write(q"EOS

Full documentation can be found on the GitHub wiki:
  https://github.com/CyberShadow/DustMite/wiki
EOS");
		return showHelp ? 0 : 64; // EX_USAGE
	}

	enforce(!(stripComments && coverageDir.length), "Sorry, --strip-comments is not compatible with --coverage");

	dir = args[1];
	if (isDirSeparator(dir[$-1]))
		dir = dir[0..$-1];

	if (args.length>=3)
		tester = args[2];

	bool isDotName(string fn) { return fn.startsWith(".") && !(fn=="." || fn==".."); }

	if (!force && isDir(dir))
		foreach (string path; dirEntries(dir, SpanMode.breadth))
			if (isDotName(baseName(path)) || isDotName(baseName(dirName(path))) || extension(path)==".o" || extension(path)==".obj" || extension(path)==".exe")
			{
				stderr.writefln("Suspicious file found: %s\nYou should use a clean copy of the source tree.\nIf it was your intention to include this file in the file-set to be reduced,\nre-run dustmite with the --force option.", path);
				return 1;
			}

	ParseRule parseSplitRule(string rule)
	{
		auto p = rule.lastIndexOf(':');
		enforce(p > 0, "Invalid parse rule: " ~ rule);
		auto pattern = rule[0..p];
		auto splitterName = rule[p+1..$];
		auto splitterIndex = splitterNames.countUntil(splitterName);
		enforce(splitterIndex >= 0, "Unknown splitter: " ~ splitterName);
		return ParseRule(pattern, cast(Splitter)splitterIndex);
	}

	ParseOptions parseOptions;
	parseOptions.stripComments = stripComments;
	parseOptions.mode = obfuscate ? ParseOptions.Mode.words : ParseOptions.Mode.source;
	parseOptions.rules = splitRules.map!parseSplitRule().array();
	measure!"load"({root = loadFiles(dir, parseOptions);});
	enforce(root.children.length, "No files in specified directory");

	applyNoRemoveMagic();
	applyNoRemoveRegex(noRemoveStr, reduceOnly);
	if (coverageDir.length)
		loadCoverage(coverageDir);
	if (!obfuscate && !noOptimize)
		optimize(root);
	maxBreadth = getMaxBreadth(root);
	countDescendants(root);
	resetProgress();
	assignID(root);

	if (dump)
		dumpSet(dirSuffix("dump"));
	if (dumpHtml)
		dumpToHtml(dirSuffix("html"));

	if (tester is null)
	{
		writeln("No tester specified, exiting");
		return 0;
	}

	resultDir = dirSuffix("reduced");
	enforce(!exists(resultDir), "Result directory already exists");

	if (!test(nullReduction))
		throw new Exception("Initial test fails");

	foundAnything = false;
	if (obfuscate)
		.obfuscate(keepLength);
	else
		reduce();

	auto duration = cast(Duration)times.total.peek();
	duration = dur!"msecs"(duration.total!"msecs"); // truncate anything below ms, users aren't interested in that
	if (foundAnything)
	{
		if (noSave)
			measure!"resultSave"({safeSave(resultDir);});
		writefln("Done in %s tests and %s; reduced version is in %s", tests, duration, resultDir);
	}
	else
		writefln("Done in %s tests and %s; no reductions found", tests, duration);

	if (showTimes)
		foreach (i, t; times.tupleof)
			writefln("%s: %s", times.tupleof[i].stringof, cast(Duration)times.tupleof[i].peek());

	return 0;
}

size_t getMaxBreadth(Entity e)
{
	size_t breadth = e.children.length;
	foreach (child; e.children)
	{
		auto childBreadth = getMaxBreadth(child);
		if (breadth < childBreadth)
			breadth = childBreadth;
	}
	return breadth;
}

size_t countDescendants(Entity e)
{
	size_t n = 1;
	foreach (c; e.children)
		n += countDescendants(c);
	return e.descendants = n;
}

size_t checkDescendants(Entity e)
{
	size_t n = 1;
	foreach (c; e.children)
		n += checkDescendants(c);
	assert(e.descendants == n);
	return n;
}

size_t countFiles(Entity e)
{
	if (e.isFile)
		return 1;
	else
	{
		size_t n = 0;
		foreach (c; e.children)
			n += countFiles(c);
		return n;
	}
}

/// Try reductions at address. Edit set, save result and return true on successful reduction.
bool testAddress(size_t[] address)
{
	auto e = entityAt(address);

	if (tryReduction(Reduction(Reduction.Type.Remove, address, e)))
		return true;
	else
	if (e.head.length && e.tail.length && tryReduction(Reduction(Reduction.Type.Unwrap, address, e)))
		return true;
	else
	if (e.isFile && !concatPerformed && tryReduction(Reduction(Reduction.Type.Concat, address, e)))
		return concatPerformed = true;
	else
		return false;
}

void resetProgress()
{
	origDescendants = root.descendants;
}

void testLevel(int testDepth, out bool tested, out bool changed)
{
	tested = changed = false;
	resetProgress();

	enum MAX_DEPTH = 1024;
	size_t[MAX_DEPTH] address;

	void scan(Entity e, int depth)
	{
		if (depth < testDepth)
		{
			// recurse
			foreach_reverse (i, c; e.children)
			{
				address[depth] = i;
				scan(c, depth+1);
			}
		}
		else
		if (e.noRemove)
		{
			// skip, but don't stop going deeper
			tested = true;
		}
		else
		{
			// test
			tested = true;
			if (testAddress(address[0..depth]))
				changed = true;
		}
	}

	scan(root, 0);

	//writefln("Scan results: tested=%s, changed=%s", tested, changed);
}

void startIteration(int iterCount)
{
	writefln("############### ITERATION %d ################", iterCount);
	resetProgress();
}

/// Keep going deeper until we find a successful reduction.
/// When found, finish tests at current depth and restart from top depth (new iteration).
/// If we reach the bottom (depth with no nodes on it), we're done.
void reduceCareful()
{
	bool tested;
	int iterCount;
	do
	{
		startIteration(iterCount++);
		bool changed;
		int depth = 0;
		do
		{
			writefln("============= Depth %d =============", depth);

			testLevel(depth, tested, changed);

			depth++;
		} while (tested && !changed); // go deeper while we found something to test, but no results
	} while (tested); // stop when we didn't find anything to test
}

/// Keep going deeper until we find a successful reduction.
/// When found, go up a depth level.
/// Keep going up while we find new reductions. Repeat topmost depth level as necessary.
/// Once no new reductions are found at higher depths, jump to the next unvisited depth in this iteration.
/// If we reach the bottom (depth with no nodes on it), start a new iteration.
/// If we finish an iteration without finding any reductions, we're done.
void reduceLookback()
{
	bool iterationChanged;
	int iterCount;
	do
	{
		iterationChanged = false;
		startIteration(iterCount++);

		int depth = 0, maxDepth = 0;
		bool depthTested;

		do
		{
			writefln("============= Depth %d =============", depth);
			bool depthChanged;

			testLevel(depth, depthTested, depthChanged);

			if (depthChanged)
			{
				iterationChanged = true;
				depth--;
				if (depth < 0)
					depth = 0;
			}
			else
			{
				maxDepth++;
				depth = maxDepth;
			}
		} while (depthTested); // keep going up/down while we found something to test
	} while (iterationChanged); // stop when we couldn't reduce anything this iteration
}

/// Keep going deeper until we find a successful reduction.
/// When found, go up a depth level.
/// Keep going up while we find new reductions. Repeat topmost depth level as necessary.
/// Once no new reductions are found at higher depths, start going downwards again.
/// If we reach the bottom (depth with no nodes on it), start a new iteration.
/// If we finish an iteration without finding any reductions, we're done.
void reducePingPong()
{
	bool iterationChanged;
	int iterCount;
	do
	{
		iterationChanged = false;
		startIteration(iterCount++);

		int depth = 0;
		bool depthTested;

		do
		{
			writefln("============= Depth %d =============", depth);
			bool depthChanged;

			testLevel(depth, depthTested, depthChanged);

			if (depthChanged)
			{
				iterationChanged = true;
				depth--;
				if (depth < 0)
					depth = 0;
			}
			else
				depth++;
		} while (depthTested); // keep going up/down while we found something to test
	} while (iterationChanged); // stop when we couldn't reduce anything this iteration
}

/// Keep going deeper.
/// If we reach the bottom (depth with no nodes on it), start a new iteration.
/// If we finish an iteration without finding any reductions, we're done.
void reduceInBreadth()
{
	bool iterationChanged;
	int iterCount;
	do
	{
		iterationChanged = false;
		startIteration(iterCount++);

		int depth = 0;
		bool depthTested;

		do
		{
			writefln("============= Depth %d =============", depth);
			bool depthChanged;

			testLevel(depth, depthTested, depthChanged);

			if (depthChanged)
				iterationChanged = true;

			depth++;
		} while (depthTested); // keep going down while we found something to test
	} while (iterationChanged); // stop when we couldn't reduce anything this iteration
}

/// Look at every entity in the tree.
/// If we can reduce this entity, continue looking at its siblings.
/// Otherwise, recurse and look at its children.
/// End an iteration once we looked at an entire tree.
/// If we finish an iteration without finding any reductions, we're done.
void reduceInDepth()
{
	bool changed;
	int iterCount;
	do
	{
		changed = false;
		startIteration(iterCount++);

		enum MAX_DEPTH = 1024;
		size_t[MAX_DEPTH] address;

		void scan(Entity e, int depth)
		{
			if (e.noRemove)
			{
				// skip, but don't stop going deeper
			}
			else
			{
				// test
				if (testAddress(address[0..depth]))
				{
					changed = true;
					return;
				}
			}

			// recurse
			foreach_reverse (i, c; e.children)
			{
				address[depth] = i;
				scan(c, depth+1);
			}
		}

		scan(root, 0);
	} while (changed && root.children.length); // stop when we couldn't reduce anything this iteration
}

void reduce()
{
	if (countFiles(root) < 2)
		concatPerformed = true;

	switch (strategy)
	{
		case "careful":
			return reduceCareful();
		case "lookback":
			return reduceLookback();
		case "pingpong":
			return reducePingPong();
		case "indepth":
			return reduceInDepth();
		case "inbreadth":
			return reduceInBreadth();
		default:
			throw new Exception("Unknown strategy");
	}
}

Mt19937 rng;

void obfuscate(bool keepLength)
{
	bool[string] wordSet;
	string[] words; // preserve file order

	foreach (f; root.children)
	{
		foreach (entity; parseToWords(f.filename) ~ f.children)
			if (entity.head.length && !isDigit(entity.head[0]))
				if (entity.head !in wordSet)
				{
					wordSet[entity.head] = true;
					words ~= entity.head;
				}
	}

	string idgen(size_t length)
	{
		static const first = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"; // use caps to avoid collisions with reserved keywords
		static const other = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";

		if (keepLength)
		{
			auto result = new char[length];
			foreach (i, ref c; result)
				c = (i==0 ? first : other)[uniform(0, $, rng)];

			return assumeUnique(result);
		}
		else
		{
			static int n;
			int index = n++;

			string result;
			result ~= first[index % $];
			index /= first.length;

			while (index)
				result ~= other[index % $],
				index /= other.length;

			return result;
		}
	}

	auto r = Reduction(Reduction.Type.ReplaceWord);
	r.total = words.length;
	foreach (i, word; words)
	{
		r.index = i;
		r.from = word;
		int tries = 0;
		do
			r.to = idgen(word.length);
		while (r.to in wordSet && tries++ < 10);
		wordSet[r.to] = true;

		tryReduction(r);
	}
}

bool skipEntity(Entity e)
{
	if (e.removed)
		return true;
	foreach (dependency; e.dependencies)
		if (skipEntity(dependency))
			return true;
	return false;
}

void dump(Entity root, ref Reduction reduction, void delegate(string) handleFile, void delegate(string) handleText)
{
	void dumpEntity(Entity e)
	{
		if (reduction.type == Reduction.Type.ReplaceWord)
		{
			if (e.isFile)
			{
				assert(e.head.length==0 && e.tail.length==0);
				handleFile(applyReductionToPath(e.filename, reduction));
				foreach (c; e.children)
					dumpEntity(c);
			}
			else
			if (e.head.length || e.tail.length)
			{
				assert(e.children.length==0);
				if (e.head.length)
				{
					if (e.head == reduction.from)
						handleText(reduction.to);
					else
						handleText(e.head);
				}
				handleText(e.tail);
			}
			else
				foreach (c; e.children)
					dumpEntity(c);
		}
		else
		if (e is reduction.target)
		{
			final switch (reduction.type)
			{
			case Reduction.Type.None:
			case Reduction.Type.ReplaceWord:
				assert(0);
			case Reduction.Type.Remove: // skip this entity
				return;
			case Reduction.Type.Unwrap: // skip head/tail
				foreach (c; e.children)
					dumpEntity(c);
				break;
			case Reduction.Type.Concat: // write contents of all files to this one; leave other files empty
				handleFile(e.filename);

				void dumpFileContent(Entity e)
				{
					foreach (f; e.children)
						if (f.isFile)
							foreach (c; f.children)
								dumpEntity(c);
						else
							dumpFileContent(f);
				}
				dumpFileContent(root);
				break;
			}
		}
		else
		if (skipEntity(e))
			return;
		else
		if (e.isFile)
		{
			handleFile(e.filename);
			if (reduction.type == Reduction.Type.Concat) // not the target - writing an empty file
				return;
			foreach (c; e.children)
				dumpEntity(c);
		}
		else
		{
			if (e.head.length) handleText(e.head);
			foreach (c; e.children)
				dumpEntity(c);
			if (e.tail.length) handleText(e.tail);
		}
	}

	debug verifyNotRemoved(root);
	if (reduction.type == Reduction.Type.Remove)
		markRemoved(reduction.target, true); // Needed for dependencies

	dumpEntity(root);

	if (reduction.type == Reduction.Type.Remove)
		markRemoved(reduction.target, false);
	debug verifyNotRemoved(root);
}

void save(Reduction reduction, string savedir)
{
	safeMkdir(savedir);

	File o;

	void handleFile(string fn)
	{
		auto path = buildPath(savedir, fn);
		if (!exists(dirName(path)))
			safeMkdir(dirName(path));

		if (o.isOpen)
			o.close();
		o.open(path, "wb");
	}

	dump(root, reduction, &handleFile, &o.write!string);

	if (o.isOpen)
		o.close();
}

Entity entityAt(size_t[] address)
{
	Entity e = root;
	foreach (a; address)
		e = e.children[a];
	return e;
}

/// Try specified reduction. If it succeeds, apply it permanently and save intermediate result.
bool tryReduction(Reduction r)
{
	if (test(r))
	{
		foundAnything = true;
		debug
			auto hashBefore = hash(r);
		applyReduction(r);
		debug
		{
			auto hashAfter = hash(nullReduction);
			assert(hashBefore == hashAfter, "Reduction preview/application mismatch");
		}
		saveResult();
		return true;
	}
	return false;
}

void verifyNotRemoved(Entity e)
{
	assert(!e.removed);
	foreach (c; e.children)
		verifyNotRemoved(c);
}

void markRemoved(Entity e, bool value)
{
	assert(e.removed == !value);
	e.removed = value;
	foreach (c; e.children)
		markRemoved(c, value);
}

/// Permanently apply specified reduction to set.
void applyReduction(ref Reduction r)
{
	final switch (r.type)
	{
		case Reduction.Type.None:
			return;
		case Reduction.Type.ReplaceWord:
		{
			foreach (ref f; root.children)
			{
				f.filename = applyReductionToPath(f.filename, r);
				foreach (ref entity; f.children)
					if (entity.head == r.from)
						entity.head = r.to;
			}
			return;
		}
		case Reduction.Type.Remove:
		{
			debug verifyNotRemoved(root);

			markRemoved(entityAt(r.address), true);

			if (r.address.length)
			{
				auto casualties = entityAt(r.address).descendants;
				foreach (n; 0..r.address.length)
					entityAt(r.address[0..n]).descendants -= casualties;

				auto p = entityAt(r.address[0..$-1]);
				p.children = remove(p.children, r.address[$-1]);
			}
			else
				root = new Entity();

			debug verifyNotRemoved(root);
			debug checkDescendants(root);
			return;
		}
		case Reduction.Type.Unwrap:
			with (entityAt(r.address))
				head = tail = null;
			return;
		case Reduction.Type.Concat:
		{
			Entity[] allData;
			void scan(Entity e)
			{
				if (e.isFile)
				{
					allData ~= e.children;
					e.children = null;
				}
				else
					foreach (c; e.children)
						scan(c);
			}

			scan(root);

			r.target.children = allData;
			optimize(r.target);
			countDescendants(root);

			return;
		}
	}
}

string applyReductionToPath(string path, Reduction reduction)
{
	if (reduction.type == Reduction.Type.ReplaceWord)
	{
		Entity[] words = parseToWords(path);
		string result;
		foreach (i, word; words)
		{
			if (i > 0 && i == words.length-1 && words[i-1].tail.endsWith("."))
				result ~= word.head; // skip extension
			else
			if (word.head == reduction.from)
				result ~= reduction.to;
			else
				result ~= word.head;
			result ~= word.tail;
		}
		return result;
	}
	return path;
}

void autoRetry(void delegate() fun, string operation)
{
	while (true)
		try
		{
			fun();
			return;
		}
		catch (Exception e)
		{
			writeln("Error while attempting to " ~ operation ~ ": " ~ e.msg);
			import core.thread;
			Thread.sleep(dur!"seconds"(1));
			writeln("Retrying...");
		}
}

/// Alternative way to check for file existence
/// Files marked for deletion act as inexistant, but still prevent creation and appear in directory listings
bool exists2(string path)
{
	return array(dirEntries(dirName(path), baseName(path), SpanMode.shallow)).length > 0;
}

void deleteAny(string path)
{
	if (exists(path))
	{
		if (isDir(path))
			rmdirRecurse(path);
		else
			remove(path);
	}
	enforce(!exists(path) && !exists2(path), "Path still exists"); // Windows only marks locked directories for deletion
}

void safeDelete(string path) { autoRetry({deleteAny(path);}, "delete " ~ path); }
void safeRename(string src, string dst) { autoRetry({rename(src, dst);}, "rename " ~ src ~ " to " ~ dst); }
void safeMkdir(string path) { autoRetry({mkdirRecurse(path);}, "mkdir " ~ path); }

void safeReplace(string path, void delegate(string path) creator)
{
	auto tmpPath = path ~ ".inprogress";
	if (exists(tmpPath)) safeDelete(tmpPath);
	auto oldPath = path ~ ".old";
	if (exists(oldPath)) safeDelete(oldPath);

	{
		scope(failure) safeDelete(tmpPath);
		creator(tmpPath);
	}

	if (exists(path)) safeRename(path, oldPath);
	safeRename(tmpPath, path);
	if (exists(oldPath)) safeDelete(oldPath);
}


void safeSave(string savedir) { safeReplace(savedir, path => save(nullReduction, path)); }

void saveResult()
{
	if (!noSave)
		measure!"resultSave"({safeSave(resultDir);});
}

version(HAVE_AE)
{
	// Use faster murmurhash from http://github.com/CyberShadow/ae
	// when compiled with -version=HAVE_AE

	import ae.utils.digest;
	import ae.utils.textout;

	alias MH3Digest128 HASH;

	HASH hash(Reduction reduction)
	{
		static StringBuffer sb;
		sb.clear();
		auto writer = &sb.put!string;
		dump(root, reduction, writer, writer);
		return murmurHash3_128(sb.get());
	}

	alias digestToStringMH3 formatHash;
}
else
{
	import std.digest.md;

	alias ubyte[16] HASH;

	HASH hash(Reduction reduction)
	{
		ubyte[16] digest;
		MD5 context;
		context.start();
		auto writer = cast(void delegate(string))&context.put;
		dump(root, reduction, writer, writer);
		return context.finish();
	}

	alias toHexString formatHash;
}

bool[HASH] cache;

bool test(Reduction reduction)
{
	write(reduction, " => "); stdout.flush();

	HASH digest;
	measure!"cacheHash"({ digest = hash(reduction); });

	bool ramCached(lazy bool fallback)
	{
		auto cacheResult = digest in cache;
		if (cacheResult)
		{
			// Note: as far as I can see, a cache hit for a positive reduction is not possible (except, perhaps, for a no-op reduction)
			writeln(*cacheResult ? "Yes" : "No", " (cached)");
			return *cacheResult;
		}
		auto result = fallback;
		return cache[digest] = result;
	}

	bool diskCached(lazy bool fallback)
	{
		tests++;

		if (globalCache.length)
		{
			if (!exists(globalCache)) mkdirRecurse(globalCache);
			string cacheBase = absolutePath(buildPath(globalCache, formatHash(digest))) ~ "-";
			bool found;

			measure!"globalCache"({ found = exists(cacheBase~"0"); });
			if (found)
			{
				writeln("No (disk cache)");
				return false;
			}
			measure!"globalCache"({ found = exists(cacheBase~"1"); });
			if (found)
			{
				writeln("Yes (disk cache)");
				return true;
			}
			auto result = fallback;
			measure!"globalCache"({ autoRetry({ std.file.write(cacheBase ~ (result ? "1" : "0"), ""); }, "save result to disk cache"); });
			return result;
		}
		else
			return fallback;
	}

	bool doTest()
	{
		string testdir = dirSuffix("test");
		measure!"testSave"({save(reduction, testdir);}); scope(exit) measure!"clean"({safeDelete(testdir);});

		auto lastdir = getcwd(); scope(exit) chdir(lastdir);
		chdir(testdir);

		Pid pid;
		if (noRedirect)
			pid = spawnShell(tester);
		else
		{
			File nul;
			version (Windows)
				nul.open("nul", "w+");
			else
				nul.open("/dev/null", "w+");
			pid = spawnShell(tester, nul, nul, nul);
		}

		bool result;
		measure!"test"({result = pid.wait() == 0;});
		writeln(result ? "Yes" : "No");
		return result;
	}

	auto result = ramCached(diskCached(doTest()));
	if (trace) saveTrace(reduction, dirSuffix("trace"), result);
	return result;
}

void saveTrace(Reduction reduction, string dir, bool result)
{
	if (!exists(dir)) mkdir(dir);
	static size_t count;
	string countStr = format("%08d-#%08d-%d", count++, reduction.target ? reduction.target.id : 0, result ? 1 : 0);
	auto traceDir = buildPath(dir, countStr);
	save(reduction, traceDir);
}

void applyNoRemoveMagic()
{
	enum MAGIC_START = "DustMiteNoRemoveStart";
	enum MAGIC_STOP  = "DustMiteNoRemoveStop";

	bool state = false;

	bool scanString(string s)
	{
		if (s.length == 0)
			return false;
		if (s.canFind(MAGIC_START))
			state = true;
		if (s.canFind(MAGIC_STOP))
			state = false;
		return state;
	}

	bool scan(Entity e)
	{
		bool removeThis;
		removeThis  = scanString(e.head);
		foreach (c; e.children)
			removeThis |= scan(c);
		removeThis |= scanString(e.tail);
		e.noRemove |= removeThis;
		return removeThis;
	}

	scan(root);
}

void applyNoRemoveRegex(string[] noRemoveStr, string[] reduceOnly)
{
	auto noRemove = array(map!((string s) { return regex(s, "mg"); })(noRemoveStr));

	void mark(Entity e)
	{
		e.noRemove = true;
		foreach (c; e.children)
			mark(c);
	}

	auto files = root.isFile ? [root] : root.children;

	foreach (f; files)
	{
		assert(f.isFile);

		if
		(
			(reduceOnly.length && !reduceOnly.any!(mask => globMatch(f.filename, mask)))
		||
			(noRemove.any!(a => !match(f.filename, a).empty))
		)
		{
			mark(f);
			root.noRemove = true;
			continue;
		}

		immutable(char)*[] starts, ends;

		foreach (r; noRemove)
			foreach (c; match(f.contents, r))
			{
				assert(c.hit.ptr >= f.contents.ptr && c.hit.ptr < f.contents.ptr+f.contents.length);
				starts ~= c.hit.ptr;
				ends ~= c.hit.ptr + c.hit.length;
			}

		starts.sort();
		ends.sort();

		int noRemoveLevel = 0;

		bool scanString(string s)
		{
			if (!s.length)
				return noRemoveLevel > 0;

			auto start = s.ptr;
			auto end = start + s.length;
			assert(start >= f.contents.ptr && end <= f.contents.ptr+f.contents.length);

			while (starts.length && starts[0] < end)
			{
				noRemoveLevel++;
				starts = starts[1..$];
			}
			bool result = noRemoveLevel > 0;
			while (ends.length && ends[0] <= end)
			{
				noRemoveLevel--;
				ends = ends[1..$];
			}
			return result;
		}

		bool scan(Entity e)
		{
			bool result = false;
			if (scanString(e.head))
				result = true;
			foreach (c; e.children)
				if (scan(c))
					result = true;
			if (scanString(e.tail))
				result = true;
			if (result)
				e.noRemove = root.noRemove = true;
			return result;
		}

		scan(f);
	}
}

void loadCoverage(string dir)
{
	void scanFile(Entity f)
	{
		auto fn = buildPath(dir, setExtension(baseName(f.filename), "lst"));
		if (!exists(fn))
			return;
		writeln("Loading coverage file ", fn);

		static bool covered(string line)
		{
			enforce(line.length >= 8 && line[7]=='|', "Invalid syntax in coverage file");
			line = line[0..7];
			return line != "0000000" && line != "       ";
		}

		auto lines = map!covered(splitLines(readText(fn))[0..$-1]);
		uint line = 0;

		bool coverString(string s)
		{
			bool result;
			foreach (char c; s)
			{
				result |= lines[line];
				if (c == '\n')
					line++;
			}
			return result;
		}

		bool cover(ref Entity e)
		{
			bool result;
			result |= coverString(e.head);
			foreach (ref c; e.children)
				result |= cover(c);
			result |= coverString(e.tail);

			e.noRemove |= result;
			return result;
		}

		foreach (ref c; f.children)
			f.noRemove |= cover(c);
	}

	void scanFiles(Entity e)
	{
		if (e.isFile)
			scanFile(e);
		else
			foreach (c; e.children)
				scanFiles(c);
	}

	scanFiles(root);
}

void assignID(Entity e)
{
	static int counter;
	e.id = ++counter;
	foreach (c; e.children)
		assignID(c);
}

void dumpSet(string fn)
{
	auto f = File(fn, "wt");

	string printable(string s) { return s is null ? "null" : `"` ~ s.replace("\\", `\\`).replace("\"", `\"`).replace("\r", `\r`).replace("\n", `\n`) ~ `"`; }
	string printableFN(string s) { return "/*** " ~ s ~ " ***/"; }

	bool[int] dependents;
	void scanDependents(Entity e)
	{
		foreach (d; e.dependencies)
			dependents[d.id] = true;
		foreach (c; e.children)
			scanDependents(c);
	}
	scanDependents(root);

	void print(Entity e, int depth)
	{
		auto prefix = replicate("  ", depth);

		// if (!fileLevel) { f.writeln(prefix, "[ ... ]"); continue; }

		f.write(prefix);
		if (e.children.length == 0)
		{
			f.write(
				"[",
				e.noRemove ? "!" : "",
				" ",
				e.isFile ? e.filename.length ? printableFN(e.filename) ~ " " : null : e.head.length ? printable(e.head) ~ " " : null,
				e.tail.length ? printable(e.tail) ~ " " : null,
				e.comment.length ? "/* " ~ e.comment ~ " */ " : null,
				"]"
			);
		}
		else
		{
			f.writeln("[", e.noRemove ? "!" : "", e.comment.length ? " // " ~ e.comment : null);
			if (e.isFile) f.writeln(prefix, "  ", printableFN(e.filename));
			if (e.head.length) f.writeln(prefix, "  ", printable(e.head));
			foreach (c; e.children)
				print(c, depth+1);
			if (e.tail.length) f.writeln(prefix, "  ", printable(e.tail));
			f.write(prefix, "]");
		}
		if (e.id in dependents || trace)
			f.write(" =", e.id);
		if (e.dependencies.length)
		{
			f.write(" =>");
			foreach (d; e.dependencies)
				f.write(" ", d.id);
		}
		f.writeln();
	}

	print(root, 0);

	f.close();
}

void dumpToHtml(string fn)
{
	auto buf = appender!string();

	void dumpText(string s)
	{
		foreach (c; s)
			switch (c)
			{
				case '<':
					buf.put("&lt;");
					break;
				case '>':
					buf.put("&gt;");
					break;
				case '&':
					buf.put("&amp;");
					break;
				default:
					buf.put(c);
			}
	}

	void dump(Entity e)
	{
		if (e.isFile)
		{
			buf.put("<h1>");
			dumpText(e.filename);
			buf.put("</h1><pre>");
			foreach (c; e.children)
				dump(c);
			buf.put("</pre>");
		}
		else
		{
			buf.put("<span>");
			dumpText(e.head);
			foreach (c; e.children)
				dump(c);
			dumpText(e.tail);
			buf.put("</span>");
		}
	}

	buf.put(q"EOT
<style> pre span:hover { outline: 1px solid rgba(0,0,0,0.2); background-color: rgba(100,100,100,0.1	); } </style>
EOT");

	dump(root);

	std.file.write(fn, buf.data());
}

void dumpText(string fn, ref Reduction r = nullReduction)
{
	auto f = File(fn, "wt");
	dump(root, r, (string) {}, &f.write!string);
	f.close();
}
