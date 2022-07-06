/// DustMite, a general-purpose data reduction tool
/// Written by Vladimir Panteleev <vladimir@thecybershadow.net>
/// License: Boost Software License, Version 1.0

module dustmite;

import core.atomic;
import core.thread;

import std.algorithm;
import std.array;
import std.ascii;
import std.container.rbtree;
import std.conv;
import std.datetime;
import std.datetime.stopwatch : StopWatch;
import std.exception;
import std.file;
import std.getopt;
import std.math : nextPow2;
import std.path;
import std.parallelism : totalCPUs;
import std.process;
import std.random;
import std.range;
import std.regex;
import std.stdio : stdout, stderr, File;
import std.string;
import std.typecons;

import splitter;

alias Splitter = splitter.Splitter;

// Issue 314 workarounds
alias join = std.string.join;
alias startsWith = std.algorithm.searching.startsWith;

string dir, resultDir, tmpDir, tester, globalCache;
string dirSuffix(string suffix, Flag!q{temp} temp)
{
	return (
		(temp && tmpDir ? tmpDir.buildPath(dir.baseName) : dir)
		.absolutePath().buildNormalizedPath() ~ "." ~ suffix
	).relativePath();
}

size_t maxBreadth;
size_t origDescendants;
int tests, maxSteps = -1; bool foundAnything;
bool noSave, trace, noRedirect, doDump, whiteout;
RemoveRule[] rejectRules;
string strategy = "inbreadth";

struct Times { StopWatch total, load, testSave, resultSave, apply, lookaheadApply, lookaheadWaitThread, lookaheadWaitProcess, test, clean, globalCache, misc; }
Times times;
static this() { times.total.start(); times.misc.start(); }
void measure(string what)(scope void delegate() p)
{
	times.misc.stop(); mixin("times."~what~".start();");
	p();
	mixin("times."~what~".stop();"); times.misc.start();
}

struct Reduction
{
	enum Type { None, Remove, Unwrap, Concat, ReplaceWord, Swap }
	Type type;
	Entity root;

	// Remove / Unwrap / Concat / Swap
	const(Address)* address;
	// Swap
	const(Address)* address2;

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
			{
				auto address = addressToArr(this.address);
				string[] segments = new string[address.length];
				Entity e = root;
				size_t progress;
				bool binary = maxBreadth == 2;
				foreach (i, a; address)
				{
					auto p = a;
					foreach (c; e.children[0..a])
						if (c.dead)
							p--;
					segments[i] = binary ? text(p) : format("%d/%d", e.children.length-a, e.children.length);
					foreach (c; e.children[0..a])
						progress += c.descendants;
					progress++; // account for this node
					e = e.children[a];
				}
				progress += e.descendants;
				auto progressPM = (origDescendants-progress) * 1000 / origDescendants; // per-mille
				return format("[%2d.%d%%] %s [%s]", progressPM/10, progressPM%10, name, segments.join(binary ? "" : ", "));
			}
			case Reduction.Type.Swap:
			{
				static string addressToString(Entity root, const(Address)* addressPtr)
				{
					auto address = addressToArr(findEntityEx(root, addressPtr).address);
					string[] segments = new string[address.length];
					bool binary = maxBreadth == 2;
					Entity e = root;
					foreach (i, a; address)
					{
						auto p = a;
						foreach (c; e.children[0..a])
							if (c.dead)
								p--;
						segments[i] = binary ? text(p) : format("%d/%d", e.children.length-a, e.children.length);
						e = e.children[a];
					}
					return segments.join(binary ? "" : ", ");
				}
				return format("[%s] <-> [%s]",
					addressToString(root, address),
					addressToString(root, address2));
			}
		}
	}
}

Address rootAddress;

auto nullReduction = Reduction(Reduction.Type.None);

struct RemoveRule { Regex!char regexp; string shellGlob; bool remove; }

int main(string[] args)
{
	bool force, dumpHtml, dumpJson, readJson, showTimes, stripComments, obfuscate, fuzz, keepLength, showHelp, showVersion, noOptimize, inPlace;
	string coverageDir;
	RemoveRule[] removeRules;
	string[] splitRules;
	uint lookaheadCount, tabWidth = 8;

	args = args
		.filter!((string arg) {
			if (arg.skipOver("-j"))
			{
				lookaheadCount = arg.length ? arg.to!uint : totalCPUs;
				return false;
			}
			return true;
		})
		// Work around getopt's inability to handle "-" in 2.080.0
		.map!((string arg) => arg == "-" ? "\0" ~ arg : arg)
		.array();

	getopt(args,
		"force", &force,
		"reduceonly|reduce-only", (string opt, string value) { removeRules ~= RemoveRule(Regex!char.init, value, true); },
		"remove"                , (string opt, string value) { removeRules ~= RemoveRule(regex(value, "mg"), null, true); },
		"noremove|no-remove"    , (string opt, string value) { removeRules ~= RemoveRule(regex(value, "mg"), null, false); },
		"reject"                , (string opt, string value) { rejectRules ~= RemoveRule(regex(value, "mg"), null, true); },
		"strip-comments", &stripComments,
		"whiteout|white-out", &whiteout,
		"coverage", &coverageDir,
		"obfuscate", &obfuscate,
		"fuzz", &fuzz,
		"keep-length", &keepLength,
		"strategy", &strategy,
		"split", &splitRules,
		"dump", &doDump,
		"dump-html", &dumpHtml,
		"dump-json", &dumpJson,
		"times", &showTimes,
		"noredirect|no-redirect", &noRedirect,
		"cache", &globalCache, // for research
		"trace", &trace, // for debugging
		"nosave|no-save", &noSave, // for research
		"nooptimize|no-optimize", &noOptimize, // for research
		"tab-width", &tabWidth,
		"temp-dir", &tmpDir,
		"max-steps", &maxSteps, // for research / benchmarking
		"i|in-place", &inPlace,
		"json", &readJson,
		"h|help", &showHelp,
		"V|version", &showVersion,
	);
	foreach (ref arg; args)
		arg.skipOver("\0"); // Undo getopt hack

	if (showVersion)
	{
		version (Dlang_Tools)
			enum source = "dlang/tools";
		else
		version (Dustmite_CustomSource) // Packaging Dustmite separately for a distribution?
			enum source = import("source");
		else
			enum source = "upstream";
		stdout.writeln("DustMite build ", __DATE__, " (", source, "), built with ", __VENDOR__, " ", __VERSION__);
		if (args.length == 1)
			return 0;
	}

	if (showHelp || args.length == 1 || args.length>3)
	{
		stderr.writef(q"EOS
Usage: %s [OPTION]... PATH TESTER
PATH should contain a clean copy of the file-set to reduce.
TESTER should be a shell command which returns 0 for a correct reduction,
and anything else otherwise.
Supported options:
  --force            Force reduction of unusual files
  --reduce-only MASK Only reduce paths glob-matching MASK
                       (may be used multiple times)
  --remove REGEXP    Only reduce blocks covered by REGEXP
                       (may be used multiple times)
  --no-remove REGEXP Do not reduce blocks containing REGEXP
                       (may be used multiple times)
  --reject REGEXP    Reject reductions which cause REGEXP to occur in output
                       (may be used multiple times)
  --strip-comments   Attempt to remove comments from source code
  --white-out        Replace deleted text with spaces to preserve line numbers
  --coverage DIR     Load .lst files corresponding to source files from DIR
  --fuzz             Instead of reducing, fuzz the input by performing random
                       changes until TESTER returns 0
  --obfuscate        Instead of reducing, obfuscate the input by replacing
                       words with random substitutions
  --keep-length      Preserve word length when obfuscating
  --split MASK:MODE  Parse and reduce files specified by MASK using the given
                       splitter. Can be repeated. MODE must be one of:
                       %-(%s, %)
  --json             Load PATH as a JSON file (same syntax as --dump-json)
  --no-redirect      Don't redirect stdout/stderr streams of test command
  --temp-dir         Write and run reduction candidates in this directory
  -j[N]              Use N look-ahead processes (%d by default)
EOS", args[0], splitterNames, totalCPUs);

		if (!showHelp)
		{
			stderr.write(q"EOS
  -h, --help         Show this message and some less interesting options
EOS");
		}
		else
		{
			stderr.write(q"EOS
  -h, --help         Show this message
Less interesting options:
  -V, --version      Show program version
  --strategy STRAT   Set strategy (careful/lookback/pingpong/indepth/inbreadth)
  --dump             Dump parsed tree to PATH.dump file
  --dump-html        Dump parsed tree to PATH.html file
  --dump-json        Dump parsed tree to PATH.json file
  --times            Display verbose spent time breakdown
  --cache DIR        Use DIR as persistent disk cache
                       (in addition to memory cache)
  --trace            Save all attempted reductions to DIR.trace
  -i, --in-place     Overwrite input with results
  --no-save          Disable saving in-progress results
  --no-optimize      Disable tree optimization step
                       (may be useful with --dump)
  --max-steps N      Perform no more than N steps when reducing
  --tab-width N      How many spaces one tab is equivalent to
                       (for the "indent" split mode)
EOS");
		}
		stderr.write(q"EOS

Full documentation can be found on the GitHub wiki:
  https://github.com/CyberShadow/DustMite/wiki
EOS");
		return showHelp ? 0 : 64; // EX_USAGE
	}

	enforce(!(stripComments && coverageDir), "Sorry, --strip-comments is not compatible with --coverage");

	dir = args[1];
	if (isDirSeparator(dir[$-1]))
		dir = dir[0..$-1];

	if (args.length>=3)
		tester = args[2];

	bool isDotName(string fn) { return fn.startsWith(".") && !(fn=="." || fn==".."); }

	if (!readJson && !force && dir.exists && dir.isDir())
	{
		bool suspiciousFilesFound;
		foreach (string path; dirEntries(dir, SpanMode.breadth))
			if (isDotName(baseName(path)) || isDotName(baseName(dirName(path))) || extension(path)==".o" || extension(path)==".obj" || extension(path)==".exe")
			{
				stderr.writeln("Warning: Suspicious file found: ", path);
				suspiciousFilesFound = true;
			}
		if (suspiciousFilesFound)
			stderr.writeln("You should use a clean copy of the source tree.\nIf it was your intention to include this file in the file-set to be reduced,\nyou can use --force to silence this message.");
	}

	ParseRule parseSplitRule(string rule)
	{
		auto p = rule.lastIndexOf(':');
		string pattern, splitterName;
		if (p < 0)
		{
			pattern = "*";
			splitterName = rule;
		}
		else
		{
			enforce(p > 0, "Invalid parse rule: " ~ rule);
			pattern = rule[0 .. p];
			splitterName = rule[p + 1 .. $];
		}
		auto splitterIndex = splitterNames.countUntil(splitterName);
		enforce(splitterIndex >= 0, "Unknown splitter: " ~ splitterName);
		return ParseRule(pattern, cast(Splitter)splitterIndex);
	}

	Entity root;

	ParseOptions parseOptions;
	parseOptions.stripComments = stripComments;
	parseOptions.mode =
		readJson ? ParseOptions.Mode.json :
		obfuscate ? ParseOptions.Mode.words :
		ParseOptions.Mode.source;
	parseOptions.rules = splitRules.map!parseSplitRule().array();
	parseOptions.tabWidth = tabWidth;
	measure!"load"({root = loadFiles(dir, parseOptions);});
	enforce(root.children.length, "No files in specified directory");

	applyNoRemoveMagic(root);
	applyNoRemoveRules(root, removeRules);
	applyNoRemoveDeps(root);
	if (coverageDir)
		loadCoverage(root, coverageDir);
	if (!obfuscate && !noOptimize)
		optimize(root);
	maxBreadth = getMaxBreadth(root);
	assignID(root);
	convertRefs(root);
	recalculate(root);
	resetProgress(root);

	if (doDump)
		dumpSet(root, dirSuffix("dump", No.temp));
	if (dumpHtml)
		dumpToHtml(root, dirSuffix("html", No.temp));
	if (dumpJson)
		dumpToJson(root, dirSuffix("json", No.temp));

	if (tester is null)
	{
		stderr.writeln("No tester specified, exiting");
		return 0;
	}

	if (inPlace)
		resultDir = dir;
	else
	{
		resultDir = dirSuffix("reduced", No.temp);
		if (resultDir.exists)
		{
			stderr.writeln("Hint: read https://github.com/CyberShadow/DustMite/wiki#result-directory-already-exists");
			throw new Exception("Result directory already exists");
		}
	}

	if (!fuzz)
	{
		auto nullResult = test(root, [nullReduction]);
		if (!nullResult.success)
		{
			auto testerFile = dir.buildNormalizedPath(tester);
			version (Posix)
			{
				if (testerFile.exists && (testerFile.getAttributes() & octal!111) == 0)
					stderr.writeln("Hint: test program seems to be a non-executable file, try: chmod +x " ~ testerFile.escapeShellFileName());
			}
			if (!testerFile.exists && tester.exists)
				stderr.writeln("Hint: test program path should be relative to the source directory, try " ~
					tester.absolutePath.relativePath(dir.absolutePath).escapeShellFileName() ~
					" instead of " ~ tester.escapeShellFileName());
			if (!noRedirect)
				stderr.writeln("Hint: use --no-redirect to see test script output");
			stderr.writeln("Hint: read https://github.com/CyberShadow/DustMite/wiki#initial-test-fails");
			throw new Exception("Initial test fails: " ~ nullResult.reason);
		}
	}

	lookaheadProcesses = new Lookahead[lookaheadCount];

	foundAnything = false;
	string resultAdjective;
	if (obfuscate)
	{
		resultAdjective = "obfuscated";
		.obfuscate(root, keepLength);
	}
	else
	if (fuzz)
	{
		resultAdjective = "fuzzed";
		.fuzz(root);
	}
	else
	{
		resultAdjective = "reduced";
		reduce(root);
	}

	auto duration = times.total.peek();
	duration = dur!"msecs"(duration.total!"msecs"); // truncate anything below ms, users aren't interested in that
	if (foundAnything)
	{
		if (!root.dead)
		{
			if (noSave)
				measure!"resultSave"({safeSave(root, resultDir);});
			stderr.writefln("Done in %s tests and %s; %s version is in %s", tests, duration, resultAdjective, resultDir);
		}
		else
		{
			stderr.writeln("Hint: read https://github.com/CyberShadow/DustMite/wiki#reduced-to-empty-set");
			stderr.writefln("Done in %s tests and %s; %s to empty set", tests, duration, resultAdjective);
		}
	}
	else
		stderr.writefln("Done in %s tests and %s; no reductions found", tests, duration);

	if (showTimes)
		foreach (i, t; times.tupleof)
			stderr.writefln("%s: %s", times.tupleof[i].stringof, times.tupleof[i].peek());

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

/// An output range which only allocates a new copy on the first write
/// that's different from a given original copy.
auto cowRange(E)(E[] arr)
{
	static struct Range
	{
		void put(ref E item)
		{
			if (pos != size_t.max)
			{
				if (pos == arr.length || item != arr[pos])
				{
					arr = arr[0 .. pos];
					pos = size_t.max;
					// continue to append (appending to a slice will copy)
				}
				else
				{
					pos++;
					return;
				}
			}

			arr ~= item;
		}

		E[] get() { return pos == size_t.max ? arr : arr[0 .. pos]; }

	private:
		E[] arr;
		size_t pos; // if size_t.max, then the copy has occurred
	}
	return Range(arr);
}

/// Update computed fields for dirty nodes
void recalculate(Entity root)
{
	// Pass 1 - length + hash (and some other calculated fields)
	{
		bool pass1(Entity e, Address *addr)
		{
			if (e.clean)
				return false;

			auto allDependents = e.allDependents.cowRange();
			e.descendants = 1;
			e.hash = e.deadHash = EntityHash.init;
			e.contents = e.deadContents = null;

			void putString(string s)
			{
				e.hash.put(s);

				// There is a circular dependency here.
				// Calculating the whited-out string efficiently
				// requires the total length of all children,
				// which is conveniently included in the hash.
				// However, calculating the hash requires knowing
				// the whited-out string that will be written.
				// Break the cycle by calculating the hash of the
				// redundantly whited-out string explicitly here.
				if (whiteout)
					foreach (c; s)
						e.deadHash.put(c.isWhite ? c : ' ');
			}

			putString(e.filename);
			putString(e.head);

			void addDependents(R)(R range, bool fresh)
			{
				if (e.dead)
					return;

				auto oldDependents = allDependents.get();
			dependentLoop:
				foreach (const(Address)* d; range)
				{
					if (!fresh)
					{
						d = findEntity(root, d).address;
						if (!d)
							continue; // Gone
					}

					if (d.startsWith(addr))
						continue; // Internal

					// Deduplicate
					foreach (o; oldDependents)
						if (equal(d, o))
							continue dependentLoop;

					allDependents.put(d);
				}
			}
			if (e.dead)
				assert(!e.dependents);
			else
			{
				// Update dependents' addresses
				auto dependents = cowRange(e.dependents);
				foreach (d; e.dependents)
				{
					d.address = findEntity(root, d.address).address;
					if (d.address)
						dependents.put(d);
				}
				e.dependents = dependents.get();
			}
			addDependents(e.dependents.map!(d => d.address), true);

			foreach (i, c; e.children)
			{
				bool fresh = pass1(c, addr.child(i));
				e.descendants += c.descendants;
				e.hash.put(c.hash);
				e.deadHash.put(c.deadHash);
				addDependents(c.allDependents, fresh);
			}
			putString(e.tail);

			e.allDependents = allDependents.get();

			assert(e.deadHash.length == (whiteout ? e.hash.length : 0));

			if (e.dead)
			{
				e.descendants = 0;
				// Switch to the "dead" variant of this subtree's hash at this point.
				// This is irreversible (in child nodes).
				e.hash = e.deadHash;
			}

			return true;
		}
		pass1(root, &rootAddress);
	}

	// --white-out pass - calculate deadContents
	if (whiteout)
	{
		// At the top-most dirty node, start a contiguous buffer
		// which contains the concatenation of all child nodes.

		char[] buf;
		size_t pos;

		void putString(string s)
		{
			foreach (char c; s)
			{
				if (!isWhite(c))
					c = ' ';
				buf[pos++] = c;
			}
		}
		void putWhite(string s)
		{
			foreach (c; s)
				buf[pos++] = c;
		}

		// This needs to run in a second pass because we
		// need to know the total length of nodes first.
		void passWO(Entity e, bool inFile)
		{
			if (e.clean)
			{
				if (buf)
					putWhite(e.deadContents);
				return;
			}

			inFile |= e.isFile;

			assert(e.hash.length == e.deadHash.length);

			bool bufStarted;
			// We start a buffer even when outside of a file,
			// for efficiency (use one buffer across many files).
			if (!buf && e.deadHash.length)
			{
				buf = new char[e.deadHash.length];
				pos = 0;
				bufStarted = true;
			}

			auto start = pos;

			putString(e.filename);
			putString(e.head);
			foreach (c; e.children)
				passWO(c, inFile);
			putString(e.tail);
			assert(e.deadHash.length == e.hash.length);

			e.deadContents = cast(string)buf[start .. pos];

			if (bufStarted)
			{
				assert(pos == buf.length);
				buf = null;
				pos = 0;
			}

			if (inFile)
				e.contents = e.deadContents;
		}
		passWO(root, false);
	}

	{
		void passFinal(Entity e)
		{
			if (e.clean)
				return;

			foreach (c; e.children)
				passFinal(c);

			e.clean = true;
		}
		passFinal(root);
	}
}

size_t checkDescendants(Entity e)
{
	if (e.dead)
		return 0;
	size_t n = e.dead ? 0 : 1;
	foreach (c; e.children)
		n += checkDescendants(c);
	assert(e.descendants == n, "Wrong descendant count: expected %d, found %d".format(e.descendants, n));
	return n;
}

bool addressDead(Entity root, size_t[] address) // TODO: this function shouldn't exist
{
	if (root.dead)
		return true;
	if (!address.length)
		return false;
	return addressDead(root.children[address[0]], address[1..$]);
}


struct ReductionIterator
{
	Strategy strategy;

	bool done = false;

	Reduction.Type type = Reduction.Type.None;
	Entity e;

	this(Strategy strategy)
	{
		this.strategy = strategy;
		next(false);
	}

	this(this)
	{
		strategy = strategy.dup;
	}

	@property ref Entity root() { return strategy.root; }
	@property Reduction front() { return Reduction(type, root, strategy.front.addressFromArr); }

	void nextEntity(bool success) /// Iterate strategy until the next non-dead node
	{
		strategy.next(success);
		while (!strategy.done && root.addressDead(strategy.front))
			strategy.next(false);
	}

	void reset()
	{
		strategy.reset();
		type = Reduction.Type.None;
	}

	void next(bool success)
	{
		if (success && type == Reduction.Type.Concat)
			reset(); // Significant changes across the tree

		while (true)
		{
			final switch (type)
			{
				case Reduction.Type.None:
					if (strategy.done)
					{
						done = true;
						return;
					}

					e = root.entityAt(strategy.front);

					if (e.noRemove)
					{
						nextEntity(false);
						continue;
					}

					if (e is root && !root.children.length)
					{
						nextEntity(false);
						continue;
					}

					// Try next reduction type
					type = Reduction.Type.Remove;
					return;

				case Reduction.Type.Remove:
					if (success)
					{
						// Next node
						type = Reduction.Type.None;
						nextEntity(true);
						continue;
					}

					// Try next reduction type
					type = Reduction.Type.Unwrap;

					if (e.head.length && e.tail.length)
						return; // Try this
					else
					{
						success = false; // Skip
						continue;
					}

				case Reduction.Type.Unwrap:
					if (success)
					{
						// Next node
						type = Reduction.Type.None;
						nextEntity(true);
						continue;
					}

					// Try next reduction type
					type = Reduction.Type.Concat;

					if (e.isFile)
						return; // Try this
					else
					{
						success = false; // Skip
						continue;
					}

				case Reduction.Type.Concat:
					// Next node
					type = Reduction.Type.None;
					nextEntity(success);
					continue;

				case Reduction.Type.ReplaceWord:
				case Reduction.Type.Swap:
					assert(false);
			}
		}
	}
}

void resetProgress(Entity root)
{
	origDescendants = root.descendants;
}

abstract class Strategy
{
	Entity root;
	uint progressGeneration = 0;
	bool done = false;

	void copy(Strategy result) const
	{
		result.root = cast()root;
		result.progressGeneration = this.progressGeneration;
		result.done = this.done;
	}

	abstract @property size_t[] front();
	abstract void next(bool success);
	abstract void reset(); /// Invoked by ReductionIterator for significant tree changes
	int getIteration() { return -1; }
	int getDepth() { return -1; }

	final Strategy dup()
	{
		auto result = cast(Strategy)this.classinfo.create();
		copy(result);
		return result;
	}
}

class SimpleStrategy : Strategy
{
	size_t[] address;

	override void copy(Strategy target) const
	{
		super.copy(target);
		auto result = cast(SimpleStrategy)target;
		result.address = this.address.dup;
	}

	override @property size_t[] front()
	{
		assert(!done, "Done");
		return address;
	}

	override void next(bool success)
	{
		assert(!done, "Done");
	}
}

class IterativeStrategy : SimpleStrategy
{
	int iteration = 0;
	bool iterationChanged;

	override int getIteration() { return iteration; }

	override void copy(Strategy target) const
	{
		super.copy(target);
		auto result = cast(IterativeStrategy)target;
		result.iteration = this.iteration;
		result.iterationChanged = this.iterationChanged;
	}

	override void next(bool success)
	{
		super.next(success);
		iterationChanged |= success;
	}

	void nextIteration()
	{
		assert(iterationChanged, "Starting new iteration after no changes");
		reset();
	}

	override void reset()
	{
		iteration++;
		iterationChanged = false;
		address = null;
		progressGeneration++;
	}
}

/// Find the first address at the depth of address.length,
/// and populate address[] accordingly.
/// Return false if no address at that level could be found.
bool findAddressAtLevel(size_t[] address, Entity root)
{
	if (root.dead)
		return false;
	if (!address.length)
		return true;
	foreach_reverse (i, child; root.children)
	{
		if (findAddressAtLevel(address[1..$], child))
		{
			address[0] = i;
			return true;
		}
	}
	return false;
}

/// Find the next address at the depth of address.length,
/// and update address[] accordingly.
/// Return false if no more addresses at that level could be found.
bool nextAddressInLevel(size_t[] address, Entity root)
{
	if (!address.length || root.dead)
		return false;
	if (nextAddressInLevel(address[1..$], root.children[address[0]]))
		return true;
	if (!address[0])
		return false;

	foreach_reverse (i; 0..address[0])
	{
		if (findAddressAtLevel(address[1..$], root.children[i]))
		{
			address[0] = i;
			return true;
		}
	}
	return false;
}

/// Find the next address, starting from the given one
/// (going depth-first). Update address accordingly.
/// If descend is false, then skip addresses under the given one.
/// Return false if no more addresses could be found.
bool nextAddress(ref size_t[] address, Entity root, bool descend)
{
	if (root.dead)
		return false;

	if (!address.length)
	{
		if (descend && root.children.length)
		{
			address ~= [root.children.length-1];
			return true;
		}
		return false;
	}

	auto cdr = address[1..$];
	if (nextAddress(cdr, root.children[address[0]], descend))
	{
		address = address[0] ~ cdr;
		return true;
	}

	if (address[0])
	{
		address = [address[0] - 1];
		return true;
	}

	return false;
}

class LevelStrategy : IterativeStrategy
{
	bool levelChanged;
	bool invalid;

	override int getDepth() { return cast(int)address.length; }

	override void copy(Strategy target) const
	{
		super.copy(target);
		auto result = cast(LevelStrategy)target;
		result.levelChanged = this.levelChanged;
		result.invalid = this.invalid;
	}

	override void next(bool success)
	{
		super.next(success);
		levelChanged |= success;
	}

	override void nextIteration()
	{
		super.nextIteration();
		invalid = false;
		levelChanged = false;
	}

	final bool nextInLevel()
	{
		assert(!invalid, "Choose a level!");
		if (nextAddressInLevel(address, root))
			return true;
		else
		{
			invalid = true;
			return false;
		}
	}

	final @property size_t currentLevel() const { return address.length; }

	final bool setLevel(size_t level)
	{
		address.length = level;
		if (findAddressAtLevel(address, root))
		{
			invalid = false;
			levelChanged = false;
			progressGeneration++;
			return true;
		}
		else
			return false;
	}
}

/// Keep going deeper until we find a successful reduction.
/// When found, finish tests at current depth and restart from top depth (new iteration).
/// If we reach the bottom (depth with no nodes on it), we're done.
final class CarefulStrategy : LevelStrategy
{
	override void next(bool success)
	{
		super.next(success);

		if (!nextInLevel())
		{
			// End of level
			if (levelChanged)
			{
				nextIteration();
			}
			else
			if (!setLevel(currentLevel + 1))
			{
				if (iterationChanged)
					nextIteration();
				else
					done = true;
			}
		}
	}
}

/// Keep going deeper until we find a successful reduction.
/// When found, go up a depth level.
/// Keep going up while we find new reductions. Repeat topmost depth level as necessary.
/// Once no new reductions are found at higher depths, jump to the next unvisited depth in this iteration.
/// If we reach the bottom (depth with no nodes on it), start a new iteration.
/// If we finish an iteration without finding any reductions, we're done.
final class LookbackStrategy : LevelStrategy
{
	size_t maxLevel = 0;

	override void copy(Strategy target) const
	{
		super.copy(target);
		auto result = cast(LookbackStrategy)target;
		result.maxLevel = this.maxLevel;
	}

	override void nextIteration()
	{
		super.nextIteration();
		maxLevel = 0;
	}

	override void next(bool success)
	{
		super.next(success);

		if (!nextInLevel())
		{
			// End of level
			if (levelChanged)
			{
				setLevel(currentLevel ? currentLevel - 1 : 0);
			}
			else
			if (setLevel(maxLevel + 1))
			{
				maxLevel = currentLevel;
			}
			else
			{
				if (iterationChanged)
					nextIteration();
				else
					done = true;
			}
		}
	}
}

/// Keep going deeper until we find a successful reduction.
/// When found, go up a depth level.
/// Keep going up while we find new reductions. Repeat topmost depth level as necessary.
/// Once no new reductions are found at higher depths, start going downwards again.
/// If we reach the bottom (depth with no nodes on it), start a new iteration.
/// If we finish an iteration without finding any reductions, we're done.
final class PingPongStrategy : LevelStrategy
{
	override void next(bool success)
	{
		super.next(success);

		if (!nextInLevel())
		{
			// End of level
			if (levelChanged)
			{
				setLevel(currentLevel ? currentLevel - 1 : 0);
			}
			else
			if (!setLevel(currentLevel + 1))
			{
				if (iterationChanged)
					nextIteration();
				else
					done = true;
			}
		}
	}
}

/// Keep going deeper.
/// If we reach the bottom (depth with no nodes on it), start a new iteration.
/// If we finish an iteration without finding any reductions, we're done.
final class InBreadthStrategy : LevelStrategy
{
	override void next(bool success)
	{
		super.next(success);

		if (!nextInLevel())
		{
			// End of level
			if (!setLevel(currentLevel + 1))
			{
				if (iterationChanged)
					nextIteration();
				else
					done = true;
			}
		}
	}
}

/// Look at every entity in the tree.
/// If we can reduce this entity, continue looking at its siblings.
/// Otherwise, recurse and look at its children.
/// End an iteration once we looked at an entire tree.
/// If we finish an iteration without finding any reductions, we're done.
final class InDepthStrategy : IterativeStrategy
{
	final bool nextAddress(bool descend)
	{
		return .nextAddress(address, root, descend);
	}

	override void next(bool success)
	{
		super.next(success);

		if (!nextAddress(!success))
		{
			if (iterationChanged)
				nextIteration();
			else
				done = true;
		}
	}
}

ReductionIterator iter;

void reduceByStrategy(Strategy strategy)
{
	int lastIteration = -1;
	int lastDepth = -1;
	int lastProgressGeneration = -1;
	int steps = 0;

	iter = ReductionIterator(strategy);

	while (!iter.done)
	{
		if (maxSteps >= 0 && steps++ == maxSteps)
			return;

		if (lastIteration != strategy.getIteration())
		{
			stderr.writefln("############### ITERATION %d ################", strategy.getIteration());
			lastIteration = strategy.getIteration();
		}
		if (lastDepth != strategy.getDepth())
		{
			stderr.writefln("============= Depth %d =============", strategy.getDepth());
			lastDepth = strategy.getDepth();
		}
		if (lastProgressGeneration != strategy.progressGeneration)
		{
			resetProgress(iter.root);
			lastProgressGeneration = strategy.progressGeneration;
		}

		auto result = tryReduction(iter.root, iter.front);

		iter.next(result);
		predictor.put(result);
	}
}

Strategy createStrategy(string name)
{
	switch (name)
	{
		case "careful":
			return new CarefulStrategy();
		case "lookback":
			return new LookbackStrategy();
		case "pingpong":
			return new PingPongStrategy();
		case "indepth":
			return new InDepthStrategy();
		case "inbreadth":
			return new InBreadthStrategy();
		default:
			throw new Exception("Unknown strategy");
	}
}

void reduce(ref Entity root)
{
	auto strategy = createStrategy(.strategy);
	strategy.root = root;
	reduceByStrategy(strategy);
	root = strategy.root;
}

Mt19937 rng;

void obfuscate(ref Entity root, bool keepLength)
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
				c = (i==0 ? first : other)[uniform(0, cast(uint)$, rng)];

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

		tryReduction(root, r);
	}
}

void fuzz(ref Entity root)
{
	debug {} else rng.seed(unpredictableSeed);

	Address*[] allAddresses;
	void collectAddresses(Entity e, Address* addr)
	{
		allAddresses ~= addr;
		foreach (i, c; e.children)
			collectAddresses(c, addr.child(i));
	}
	collectAddresses(root, &rootAddress);

	while (true)
	{
		import std.math : log2;
		auto newRoot = root;
		auto numReductions = uniform(1, cast(int)log2(cast(double)allAddresses.length), rng);
		Reduction[] reductions;
		foreach (n; 0 .. numReductions)
		{
			static immutable Reduction.Type[] reductionTypes = [Reduction.Type.Swap];
			auto r = Reduction(reductionTypes[uniform(0, $, rng)], newRoot);
			switch (r.type)
			{
				case Reduction.Type.Swap:
					r.address  = findEntity(newRoot, allAddresses[uniform(0, $, rng)]).address;
					r.address2 = findEntity(newRoot, allAddresses[uniform(0, $, rng)]).address;
					if (r.address.startsWith(r.address2) ||
						r.address2.startsWith(r.address))
						continue;
					break;
				default:
					assert(false);
			}
			newRoot = applyReduction(newRoot, r);
			reductions ~= r;
		}
		if (newRoot is root)
			continue;

		auto result = test(newRoot, reductions);
		if (result.success)
		{
			foundAnything = true;
			root = newRoot;
			saveResult(root);
			return;
		}
	}
}

void dump(Writer)(Entity root, Writer writer)
{
	void dumpEntity(bool inFile)(Entity e)
	{
		if (e.dead)
		{
			if (inFile && e.contents.length)
				writer.handleText(e.contents[e.filename.length .. $]);
		}
		else
		if (!inFile && e.isFile)
		{
			writer.handleFile(e.filename);
			foreach (c; e.children)
				dumpEntity!true(c);
		}
		else
		{
			if (inFile && e.head.length) writer.handleText(e.head);
			foreach (c; e.children)
				dumpEntity!inFile(c);
			if (inFile && e.tail.length) writer.handleText(e.tail);
		}
	}

	dumpEntity!false(root);
}

static struct FastWriter(Next) /// Accelerates Writer interface by bulking contiguous strings
{
	Next next;
	immutable(char)* start, end;
	void finish()
	{
		if (start != end)
			next.handleText(start[0 .. end - start]);
		start = end = null;
	}
	void handleFile(string s)
	{
		finish();
		next.handleFile(s);
	}
	void handleText(string s)
	{
		if (s.ptr != end)
		{
			finish();
			start = s.ptr;
		}
		end = s.ptr + s.length;
	}
	~this() { finish(); }
}

static struct DiskWriter
{
	string dir;

	File o;
	typeof(o.lockingBinaryWriter()) binaryWriter;

	void handleFile(string fn)
	{
		finish();

		static Appender!(char[]) pathBuf;
		pathBuf.clear();
		pathBuf.put(dir.chainPath(fn));
		auto path = pathBuf.data;
		if (!exists(dirName(path)))
			safeMkdir(dirName(path));

		o.open(cast(string)path, "wb");
		binaryWriter = o.lockingBinaryWriter;
	}

	void handleText(string s)
	{
		assert(o.isOpen);
		binaryWriter.put(s);
	}

	void finish()
	{
		if (o.isOpen)
		{
			binaryWriter = typeof(binaryWriter).init;
			o.close();
			o = File.init; // Avoid crash on Windows
		}
	}

	~this() { finish(); }
}

struct MemoryWriter
{
	char[] buf;
	size_t pos;

	void handleFile(string fn) {}

	void handleText(string s)
	{
		auto end = pos + s.length;
		if (buf.length < end)
		{
			buf.length = end;
			buf.length = buf.capacity;
		}
		buf[pos .. end] = s;
		pos = end;
	}

	void reset() { pos = 0; }
	char[] data() { return buf[0 .. pos]; }
}

void save(Entity root, string savedir)
{
	safeDelete(savedir);
	safeMkdir(savedir);

	FastWriter!DiskWriter writer;
	writer.next.dir = savedir;
	dump(root, &writer);
	writer.finish();
}

Entity entityAt(Entity root, size_t[] address) // TODO: replace uses with findEntity and remove
{
	Entity e = root;
	foreach (a; address)
		e = e.children[a];
	return e;
}

Address* addressFromArr(size_t[] address) // TODO: replace uses with findEntity and remove
{
	Address* a = &rootAddress;
	foreach (index; address)
		a = a.child(index);
	return a;
}

size_t[] addressToArr(const(Address)* address)
{
	auto result = new size_t[address.depth];
	while (address.parent)
	{
		result[address.depth - 1] = address.index;
		address = address.parent;
	}
	return result;
}

/// Return true if these two addresses are the same
/// (they point to the same node).
bool equal(const(Address)* a, const(Address)* b)
{
	if (a is b)
		return true;
	if (a.depth != b.depth)
		return false;
	if (a.index != b.index)
		return false;
	assert(a.parent && b.parent); // If we are at the root node, then the address check should have passed
	return equal(a.parent, b.parent);
}
alias equal = std.algorithm.comparison.equal;

/// Returns true if the `haystack` address starts with the `needle` address,
/// i.e. the entity that needle points at is a child of the entity that haystack points at.
bool startsWith(const(Address)* haystack, const(Address)* needle)
{
	if (haystack.depth < needle.depth)
		return false;
	while (haystack.depth > needle.depth)
		haystack = haystack.parent;
	return equal(haystack, needle);
}

/// Try specified reduction. If it succeeds, apply it permanently and save intermediate result.
bool tryReduction(ref Entity root, Reduction r)
{
	Entity newRoot;
	measure!"apply"({ newRoot = root.applyReduction(r); });
	if (newRoot is root)
	{
		assert(r.type != Reduction.Type.None);
		stderr.writeln(r, " => N/A");
		return false;
	}
	if (test(newRoot, [r]).success)
	{
		foundAnything = true;
		root = newRoot;
		saveResult(root);
		return true;
	}
	return false;
}

/// Apply a reduction to this tree, and return the resulting tree.
/// The original tree remains unchanged.
/// Copies only modified parts of the tree, and whatever references them.
Entity applyReductionImpl(Entity origRoot, ref Reduction r)
{
	Entity root = origRoot;

	debug static ubyte[] treeBytes(Entity e) { return (cast(ubyte*)e)[0 .. __traits(classInstanceSize, Entity)] ~ cast(ubyte[])e.children ~ e.children.map!treeBytes.join; }
	debug auto origBytes = treeBytes(origRoot);
	scope(exit) debug assert(origBytes == treeBytes(origRoot), "Original tree was changed!");
	scope(success) debug if (root !is origRoot) assert(treeBytes(root) != origBytes, "Tree was unchanged");

	debug void checkClean(Entity e) { assert(e.clean, "Found dirty node before/after reduction"); foreach (c; e.children) checkClean(c); }
	debug checkClean(root);
	scope(success) debug checkClean(root);

	static struct EditResult
	{
		Entity entity; /// Entity at address. Never null.
		bool dead;     /// Entity or one of its parents is dead.
	}
	EditResult editImpl(const(Address)* addr)
	{
		Entity* pEntity;
		bool dead;
		if (addr.parent)
		{
			auto result = editImpl(addr.parent);
			auto parent = result.entity;
			pEntity = &parent.children[addr.index];
			dead = result.dead;
		}
		else
		{
			pEntity = &root;
			dead = false;
		}

		auto oldEntity = *pEntity;

		if (oldEntity.redirect)
		{
			assert(oldEntity.dead);
			return editImpl(oldEntity.redirect);
		}

		dead |= oldEntity.dead;

		// We can avoid copying the entity if it (or a parent) is dead, because edit()
		// will not allow such an entity to be returned back to applyReduction.
		if (!oldEntity.clean || dead)
			return EditResult(oldEntity, dead);

		auto newEntity = oldEntity.dup();
		newEntity.clean = false;
		*pEntity = newEntity;

		return EditResult(newEntity, dead);
	}
	Entity edit(const(Address)* addr) /// Returns a writable copy of the entity at the given Address
	{
		auto r = editImpl(addr);
		return r.dead ? null : r.entity;
	}

	final switch (r.type)
	{
		case Reduction.Type.None:
			break;

		case Reduction.Type.ReplaceWord:
			foreach (i; 0 .. root.children.length)
			{
				auto fa = rootAddress.children[i];
				auto f = edit(fa);
				f.filename = applyReductionToPath(f.filename, r);
				foreach (j, const word; f.children)
					if (word.head == r.from)
						edit(fa.children[j]).head = r.to;
			}
			break;
		case Reduction.Type.Remove:
		{
			assert(!findEntity(root, r.address).entity.dead, "Trying to remove a tombstone");
			void remove(const(Address)* address)
			{
				auto n = edit(address);
				if (!n)
					return; // This dependency was removed by something else
				n.dead = true; // Mark as dead early, so that we don't waste time processing dependencies under this node
				foreach (dep; n.allDependents)
					remove(dep);
				n.kill(); // Convert to tombstone
			}
			remove(r.address);
			break;
		}
		case Reduction.Type.Unwrap:
		{
			assert(!findEntity(root, r.address).entity.dead, "Trying to unwrap a tombstone");
			bool changed;
			with (edit(r.address))
				foreach (value; [&head, &tail])
				{
					string newValue = whiteout
						? cast(string)((*value).representation.map!(c => isWhite(c) ? char(c) : ' ').array)
						: null;
					changed |= *value != newValue;
					*value = newValue;
				}
			if (!changed)
				root = origRoot;
			break;
		}
		case Reduction.Type.Concat:
		{
			// Move all nodes from all files to a single file (the target).
			// Leave behind redirects.

			size_t numFiles;
			Entity[] allData;
			Entity[Entity] tombstones; // Map from moved entity to its tombstone

			// Collect the nodes to move, and leave behind tombstones.

			void collect(Entity e, Address* addr)
			{
				if (e.dead)
					return;
				if (e.isFile)
				{
					// Skip noRemove files, except when they are the target
					// (in which case they will keep their contents after the reduction).
					if (e.noRemove && !equal(addr, r.address))
						return;

					if (!e.children.canFind!(c => !c.dead))
						return; // File is empty (already concat'd?)

					numFiles++;
					allData ~= e.children;
					auto f = edit(addr);
					f.children = new Entity[e.children.length];
					foreach (i; 0 .. e.children.length)
					{
						auto tombstone = new Entity;
						tombstone.kill();
						f.children[i] = tombstone;
						tombstones[e.children[i]] = tombstone;
					}
				}
				else
					foreach (i, c; e.children)
						collect(c, addr.child(i));
			}

			collect(root, &rootAddress);

			// Fail the reduction if there are less than two files to concatenate.
			if (numFiles < 2)
			{
				root = origRoot;
				break;
			}

			auto n = edit(r.address);

			auto temp = new Entity;
			temp.children = allData;
			temp.optimizeUntil!((Entity e) => e in tombstones);

			// The optimize function rearranges nodes in a tree,
			// so we need to do a recursive scan to find their new location.
			void makeRedirects(Address* address, Entity e)
			{
				if (auto p = e in tombstones)
					p.redirect = address; // Patch the tombstone to point to the node's new location.
				else
				{
					assert(!e.clean); // This node was created by optimize(), it can't be clean
					foreach (i, child; e.children)
						makeRedirects(address.child(i), child);
				}
			}
			foreach (i, child; temp.children)
				makeRedirects(r.address.child(n.children.length + i), child);

			n.children ~= temp.children;

			break;
		}
		case Reduction.Type.Swap:
		{
			// Cannot swap child and parent.
			assert(
				!r.address.startsWith(r.address2) &&
				!r.address2.startsWith(r.address),
				"Invalid swap");
			// Corollary: neither address may be the root address.

			// Cannot swap siblings (special case).
			if (equal(r.address.parent, r.address2.parent))
				break;

			static struct SwapSite
			{
				Entity source;       /// Entity currently at this site's address
				Entity* target;      /// Where to place the other site's entity
				Address* newAddress; /// Address of target
				Entity tombstone;    /// Redirect to the other site's swap target
			}

			SwapSite prepareSwap(const(Address)* address)
			{
				auto p = edit(address.parent);
				assert(address.index < p.children.length);

				SwapSite result;
				// Duplicate children.
				// Replace the first half with redirects to the second half.
				// The second half is the same as the old children,
				// except with the target node replaced with the swap target.
				auto children = new Entity[p.children.length * 2];
				// First half:
				foreach (i; 0 .. p.children.length)
				{
					auto tombstone = new Entity;
					tombstone.kill();
					if (i == address.index)
						result.tombstone = tombstone;
					else
						tombstone.redirect = address.parent.child(p.children.length + i);
					children[i] = tombstone;
				}
				// Second half:
				foreach (i; 0 .. p.children.length)
				{
					if (i == address.index)
					{
						result.source = p.children[i];
						result.target = &children[p.children.length + i];
						result.newAddress = address.parent.child(p.children.length + i);
					}
					else
						children[p.children.length + i] = p.children[i];
				}
				p.children = children;
				return result;
			}

			auto site1 = prepareSwap(r.address);
			auto site2 = prepareSwap(r.address2);

			void finalizeSwap(ref SwapSite thisSite, ref SwapSite otherSite)
			{
				assert(otherSite.source);
				*thisSite.target = otherSite.source;
				thisSite.tombstone.redirect = otherSite.newAddress;
			}

			finalizeSwap(site1, site2);
			finalizeSwap(site2, site1);
			break;
		}
	}

	if (root !is origRoot)
		assert(!root.clean);

	recalculate(root); // Recalculate cumulative information for the part of the tree that we edited

	debug checkDescendants(root);

	return root;
}

/// Polyfill for object.require
static if (!__traits(hasMember, object, "require"))
ref V require(K, V)(ref V[K] aa, K key, lazy V value = V.init)
{
	auto p = key in aa;
	if (p)
		return *p;
	return aa[key] = value;
}

// std.functional.memoize evicts old entries after a hash collision.
// We have much to gain by evicting in strictly chronological order.
struct RoundRobinCache(K, V)
{
	V[K] lookup;
	K[] keys;
	size_t pos;

	void requireSize(size_t size)
	{
		if (keys.length >= size)
			return;
		T roundUpToPowerOfTwo(T)(T x) { return nextPow2(x-1); }
		keys.length = roundUpToPowerOfTwo(size);
	}

	ref V get(ref K key, lazy V value)
	{
		return lookup.require(key,
			{
				lookup.remove(keys[pos]);
				keys[pos++] = key;
				if (pos == keys.length)
					pos = 0;
				return value;
			}());
	}
}
alias ReductionCacheKey = Tuple!(Entity, q{origRoot}, Reduction, q{r});
RoundRobinCache!(ReductionCacheKey, Entity) reductionCache;

Entity applyReduction(Entity origRoot, ref Reduction r)
{
	if (lookaheadProcesses.length)
	{
		if (!reductionCache.keys)
			reductionCache.requireSize(1 + lookaheadProcesses.length);

		auto cacheKey = ReductionCacheKey(origRoot, r);
		return reductionCache.get(cacheKey, applyReductionImpl(origRoot, r));
	}
	else
		return applyReductionImpl(origRoot, r);
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

void autoRetry(scope void delegate() fun, lazy const(char)[] operation)
{
	while (true)
		try
		{
			fun();
			return;
		}
		catch (Exception e)
		{
			stderr.writeln("Error while attempting to " ~ operation ~ ": " ~ e.msg);
			import core.thread;
			Thread.sleep(dur!"seconds"(1));
			stderr.writeln("Retrying...");
		}
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

	// The ugliest hacks, only for the ugliest operating system
	version (Windows)
	{
		/// Alternative way to check for file existence
		/// Files marked for deletion act as inexistant, but still prevent creation and appear in directory listings
		bool exists2(string path)
		{
			return !dirEntries(dirName(path), baseName(path), SpanMode.shallow).empty;
		}

		enforce(!exists(path) && !exists2(path), "Path still exists"); // Windows only marks locked directories for deletion
	}
}

void safeDelete(string path) { autoRetry({deleteAny(path);}, "delete " ~ path); }
void safeRename(string src, string dst) { autoRetry({rename(src, dst);}, "rename " ~ src ~ " to " ~ dst); }
void safeMkdir(in char[] path) { autoRetry({mkdirRecurse(path);}, "mkdir " ~ path); }

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


void safeSave(Entity root, string savedir) { safeReplace(savedir, path => save(root, path)); }

void saveResult(Entity root)
{
	if (!noSave)
		measure!"resultSave"({safeSave(root, resultDir);});
}

struct Lookahead
{
	Thread thread;
	shared Pid pid;
	string testdir;
	EntityHash digest;
}
Lookahead[] lookaheadProcesses;

TestResult[EntityHash] lookaheadResults;

struct AccumulatingPredictor(double exp)
{
	double r = 0.5;

	void put(bool outcome)
	{
		r = (1 - exp) * r + exp * outcome;
	}

	double predict()
	{
		return r;
	}
}
// Parameters found through empirical testing (gradient descent)
alias Predictor = AccumulatingPredictor!(0.01);
Predictor predictor;

version (Windows)
	enum nullFileName = "nul";
else
	enum nullFileName = "/dev/null";

bool[EntityHash] cache;

struct TestResult
{
	bool success;

	enum Source : ubyte
	{
		none,
		tester,
		lookahead,
		diskCache,
		ramCache,
		reject,
	}
	Source source;

	int status;
	string reason()
	{
		final switch (source)
		{
			case Source.none:
				assert(false);
			case Source.tester:
				return format("Test script %(%s%) exited with exit code %d (%s)",
					[tester], status, (success ? "success" : "failure"));
			case Source.lookahead:
				return format("Test script %(%s%) (in lookahead) exited with exit code %d (%s)",
					[tester], status, (success ? "success" : "failure"));
			case Source.diskCache:
				return "Test result was cached on disk as " ~ (success ? "success" : "failure");
			case Source.ramCache:
				return "Test result was cached in memory as " ~ (success ? "success" : "failure");
			case Source.reject:
				return "Test result was rejected by a --reject rule";
		}
	}
}

TestResult test(
	Entity root,            /// New root, with reduction already applied
	Reduction[] reductions, /// For display purposes only
)
{
	stderr.writef("%-(%s, %) => ", reductions); stdout.flush();

	EntityHash digest = root.hash;

	TestResult ramCached(lazy TestResult fallback)
	{
		auto cacheResult = digest in cache;
		if (cacheResult)
		{
			// Note: as far as I can see, a cache hit for a positive reduction is not possible (except, perhaps, for a no-op reduction)
			stderr.writeln(*cacheResult ? "Yes" : "No", " (cached)");
			return TestResult(*cacheResult, TestResult.Source.ramCache);
		}
		auto result = fallback;
		cache[digest] = result.success;
		return result;
	}

	TestResult diskCached(lazy TestResult fallback)
	{
		tests++;

		if (globalCache)
		{
			if (!exists(globalCache)) mkdirRecurse(globalCache);
			string cacheBase = absolutePath(buildPath(globalCache, format("%016X", cast(ulong)digest.value))) ~ "-";
			bool found;

			measure!"globalCache"({ found = exists(cacheBase~"0"); });
			if (found)
			{
				stderr.writeln("No (disk cache)");
				return TestResult(false, TestResult.Source.diskCache);
			}
			measure!"globalCache"({ found = exists(cacheBase~"1"); });
			if (found)
			{
				stderr.writeln("Yes (disk cache)");
				return TestResult(true, TestResult.Source.diskCache);
			}
			auto result = fallback;
			measure!"globalCache"({ autoRetry({ std.file.write(cacheBase ~ (result.success ? "1" : "0"), ""); }, "save result to disk cache"); });
			return result;
		}
		else
			return fallback;
	}

	TestResult lookahead(lazy TestResult fallback)
	{
		if (iter.strategy)
		{
			// Handle existing lookahead jobs

			TestResult reap(ref Lookahead process, int status)
			{
				scope(success) process = Lookahead.init;
				safeDelete(process.testdir);
				if (process.thread)
					process.thread.join(/*rethrow:*/true);
				return lookaheadResults[process.digest] = TestResult(status == 0, TestResult.Source.lookahead, status);
			}

			foreach (ref process; lookaheadProcesses)
				if (process.thread)
				{
					debug (DETERMINISTIC_LOOKAHEAD)
					{
						process.thread.join(/*rethrow:*/true);
						process.thread = null;
					}

					auto pid = cast()atomicLoad(process.pid);
					if (pid)
					{
						debug (DETERMINISTIC_LOOKAHEAD)
							reap(process, pid.wait());
						else
						{
							auto waitResult = pid.tryWait();
							if (waitResult.terminated)
								reap(process, waitResult.status);
						}
					}
				}

			static struct PredictedState
			{
				double probability;
				ReductionIterator iter;
				Predictor predictor;
			}

			auto initialState = new PredictedState(1.0, iter, predictor);
			alias PredictionTree = RedBlackTree!(PredictedState*, (a, b) => a.probability > b.probability, true);
			auto predictionTree = new PredictionTree((&initialState)[0..1]);

			// Start new lookahead jobs

			size_t numSteps;

			foreach (ref process; lookaheadProcesses)
				while (!process.thread && !predictionTree.empty)
				{
					auto state = predictionTree.front;
					predictionTree.removeFront();

				retryIter:
					if (state.iter.done)
						continue;
					reductionCache.requireSize(lookaheadProcesses.length + ++numSteps);
					auto reduction = state.iter.front;
					Entity newRoot;
					measure!"lookaheadApply"({ newRoot = state.iter.root.applyReduction(reduction); });
					if (newRoot is state.iter.root)
					{
						state.iter.next(false);
						goto retryIter; // inapplicable reduction
					}

					auto digest = newRoot.hash;

					double prediction;
					if (digest in cache || digest in lookaheadResults || lookaheadProcesses[].canFind!(p => p.thread && p.digest == digest))
					{
						if (digest in cache)
							prediction = cache[digest] ? 1 : 0;
						else
						if (digest in lookaheadResults)
							prediction = lookaheadResults[digest].success ? 1 : 0;
						else
							prediction = state.predictor.predict();
					}
					else
					{
						process.digest = digest;

						static int counter;
						process.testdir = dirSuffix("lookahead.%d".format(counter++), Yes.temp);

						// Saving and process creation are expensive.
						// Don't block the main thread, use a worker thread instead.
						static void runThread(Entity newRoot, ref Lookahead process, string tester)
						{
							process.thread = new Thread({
								save(newRoot, process.testdir);

								auto nul = File(nullFileName, "w+");
								auto pid = spawnShell(tester, nul, nul, nul, null, Config.none, process.testdir);
								atomicStore(process.pid, cast(shared)pid);
							});
							process.thread.start();
						}
						runThread(newRoot, process, tester);

						prediction = state.predictor.predict();
					}

					foreach (outcome; 0 .. 2)
					{
						auto probability = outcome ? prediction : 1 - prediction;
						if (probability == 0)
							continue; // no chance
						probability *= state.probability; // accumulate
						auto nextState = new PredictedState(probability, state.iter, state.predictor);
						if (outcome)
							nextState.iter.root = newRoot;
						nextState.iter.next(!!outcome);
						nextState.predictor.put(!!outcome);
						predictionTree.insert(nextState);
					}
				}

			// Find a result for the current test.

			auto plookaheadResult = digest in lookaheadResults;
			if (plookaheadResult)
			{
				stderr.writeln(plookaheadResult.success ? "Yes" : "No", " (lookahead)");
				return *plookaheadResult;
			}

			foreach (ref process; lookaheadProcesses)
			{
				if (process.thread && process.digest == digest)
				{
					// Current test is already being tested in the background, wait for its result.

					// Join the thread first, to guarantee that there is a pid
					measure!"lookaheadWaitThread"({ process.thread.join(/*rethrow:*/true); });
					process.thread = null;

					auto pid = cast()atomicLoad(process.pid);
					int exitCode;
					measure!"lookaheadWaitProcess"({ exitCode = pid.wait(); });

					auto result = reap(process, exitCode);
					stderr.writeln(result.success ? "Yes" : "No", " (lookahead-wait)");
					return result;
				}
			}
		}

		return fallback;
	}

	TestResult testReject(lazy TestResult fallback)
	{
		if (rejectRules.length)
		{
			bool defaultReject = !rejectRules.front.remove;

			bool scan(Entity e)
			{
				if (e.isFile)
				{
					static MemoryWriter writer;
					writer.reset();
					dump(e, &writer);

					static bool[] removeCharBuf;
					if (removeCharBuf.length < writer.data.length)
						removeCharBuf.length = writer.data.length;
					auto removeChar = removeCharBuf[0 .. writer.data.length];
					removeChar[] = defaultReject;

					foreach (ref rule; rejectRules)
						if (rule.regexp !is Regex!char.init)
							foreach (m; writer.data.matchAll(rule.regexp))
							{
								auto start = m.hit.ptr - writer.data.ptr;
								auto end = start + m.hit.length;
								removeChar[start .. end] = rule.remove;
							}

					if (removeChar.canFind(true))
						return true;
				}
				else
					foreach (c; e.children)
						if (scan(c))
							return true;
				return false;
			}

			if (scan(root))
			{
				stderr.writeln("No (rejected)");
				return TestResult(false, TestResult.Source.reject);
			}
		}
		return fallback;
	}

	TestResult doTest()
	{
		string testdir = dirSuffix("test", Yes.temp);
		measure!"testSave"({save(root, testdir);}); scope(exit) measure!"clean"({safeDelete(testdir);});

		auto nullRead = File(nullFileName, "rb");
		Pid pid;
		if (noRedirect)
			pid = spawnShell(tester, nullRead, stdout   , stderr   , null, Config.none, testdir);
		else
		{
			auto nullWrite = File(nullFileName, "wb");
			pid = spawnShell(tester, nullRead, nullWrite, nullWrite, null, Config.none, testdir);
		}

		int status;
		measure!"test"({status = pid.wait();});
		auto result = TestResult(status == 0, TestResult.Source.tester, status);
		stderr.writeln(result.success ? "Yes" : "No");
		return result;
	}

	auto result = ramCached(diskCached(testReject(lookahead(doTest()))));
	if (trace) saveTrace(root, reductions, dirSuffix("trace", No.temp), result.success);
	return result;
}

void saveTrace(Entity root, Reduction[] reductions, string dir, bool result)
{
	if (!exists(dir)) mkdir(dir);
	static size_t count;
	string countStr = format("%08d-%(#%08d-%|%)%d",
		count++,
		reductions
			.map!(reduction => reduction.address ? findEntityEx(root, reduction.address).entity : null)
			.map!(target => target ? target.id : 0),
		result ? 1 : 0);
	auto traceDir = buildPath(dir, countStr);
	save(root, traceDir);
	if (doDump && result)
		dumpSet(root, traceDir ~ ".dump");
}

void applyNoRemoveMagic(Entity root)
{
	enum MAGIC_PREFIX = "DustMiteNoRemove";
	enum MAGIC_START = MAGIC_PREFIX ~ "Start";
	enum MAGIC_STOP  = MAGIC_PREFIX ~ "Stop";

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

void applyNoRemoveRules(Entity root, RemoveRule[] removeRules)
{
	if (!removeRules.length)
		return;

	// By default, for content not covered by any of the specified
	// rules, do the opposite of the first rule.
	// I.e., if the default rule is "remove only", then by default
	// don't remove anything except what's specified by the rule.
	bool defaultRemove = !removeRules.front.remove;

	auto files = root.isFile ? [root] : root.children;

	foreach (f; files)
	{
		assert(f.isFile);

		// Check file name
		bool removeFile = defaultRemove;
		foreach (rule; removeRules)
		{
			if (
				(rule.shellGlob && f.filename.globMatch(rule.shellGlob))
			||
				(rule.regexp !is Regex!char.init && f.filename.match(rule.regexp))
			)
				removeFile = rule.remove;
		}

		auto removeChar = new bool[f.contents.length];
		removeChar[] = removeFile;

		foreach (rule; removeRules)
			if (rule.regexp !is Regex!char.init)
				foreach (m; f.contents.matchAll(rule.regexp))
				{
					auto start = m.hit.ptr - f.contents.ptr;
					auto end = start + m.hit.length;
					removeChar[start .. end] = rule.remove;
				}

		bool scanString(string s)
		{
			if (!s.length)
				return true;
			auto start = s.ptr - f.contents.ptr;
			auto end = start + s.length;
			return removeChar[start .. end].all;
		}

		bool scan(Entity e)
		{
			bool remove = true;
			remove &= scanString(e.head);
			foreach (c; e.children)
				remove &= scan(c);
			remove &= scanString(e.tail);
			if (!remove)
				e.noRemove = root.noRemove = true;
			return remove;
		}

		scan(f);
	}
}

void applyNoRemoveDeps(Entity root)
{
	static bool isNoRemove(Entity e)
	{
		if (e.noRemove)
			return true;
		foreach (dependent; e.dependents)
			if (isNoRemove(dependent.entity))
				return true;
		return false;
	}

	// Propagate upwards
	static bool fill(Entity e)
	{
		e.noRemove |= isNoRemove(e);
		foreach (c; e.children)
			e.noRemove |= fill(c);
		return e.noRemove;
	}

	fill(root);
}

void loadCoverage(Entity root, string dir)
{
	void scanFile(Entity f)
	{
		auto fn = buildPath(dir, setExtension(baseName(f.filename), "lst"));
		if (!exists(fn))
			return;
		stderr.writeln("Loading coverage file ", fn);

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

void convertRefs(Entity root)
{
	Address*[int] addresses;

	void collectAddresses(Entity e, Address* address)
	{
		assert(e.id !in addresses);
		addresses[e.id] = address;

		assert(address.children.length == 0);
		foreach (i, c; e.children)
		{
			auto childAddress = new Address(address, i, address.depth + 1);
			address.children ~= childAddress;
			collectAddresses(c, childAddress);
		}
		assert(address.children.length == e.children.length);
	}
	collectAddresses(root, &rootAddress);

	void convertRef(ref EntityRef r)
	{
		assert(r.entity && !r.address);
		r.address = addresses[r.entity.id];
		r.entity = null;
	}

	void convertRefs(Entity e)
	{
		foreach (ref r; e.dependents)
			convertRef(r);
		foreach (c; e.children)
			convertRefs(c);
	}
	convertRefs(root);
}

struct FindResult
{
	Entity entity;          /// null if gone
	const Address* address; /// the "real" (no redirects) address, null if gone
}

FindResult findEntity(Entity root, const(Address)* addr)
{
	auto result = findEntityEx(root, addr);
	if (result.dead)
		return FindResult(null, null);
	return FindResult(result.entity, result.address);
}

struct FindResultEx
{
	Entity entity;          /// never null
	const Address* address; /// never null
	bool dead;              /// a dead node has been traversed to get here
}

static FindResultEx findEntityEx(Entity root, const(Address)* addr)
{
	if (!addr.parent) // root
		return FindResultEx(root, addr, root.dead);

	auto r = findEntityEx(root, addr.parent);
	auto e = r.entity.children[addr.index];
	if (e.redirect)
	{
		assert(e.dead);
		return findEntityEx(root, e.redirect); // shed the "dead" flag here
	}

	addr = r.address.child(addr.index); // apply redirects in parents
	return FindResultEx(e, addr, r.dead || e.dead); // accumulate the "dead" flag
}

struct AddressRange
{
	const(Address)*address;
	bool empty() { return !address.parent; }
	size_t front() { return address.index; }
	void popFront() { address = address.parent; }
}

void dumpSet(Entity root, string fn)
{
	auto f = File(fn, "wb");

	string printable(string s) { return s is null ? "null" : `"` ~ s.replace("\\", `\\`).replace("\"", `\"`).replace("\r", `\r`).replace("\n", `\n`) ~ `"`; }
	string printableFN(string s) { return "/*** " ~ s ~ " ***/"; }

	int[][int] dependencies;
	bool[int] redirects;
	void scanDependencies(Entity e)
	{
		foreach (d; e.dependents)
		{
			auto dependent = findEntityEx(root, d.address).entity;
			if (dependent)
				dependencies[dependent.id] ~= e.id;
		}
		foreach (c; e.children)
			scanDependencies(c);
		if (e.redirect)
		{
			auto target = findEntityEx(root, e.redirect).entity;
			if (target)
				redirects[target.id] = true;
		}
	}
	scanDependencies(root);

	void print(Entity e, int depth)
	{
		auto prefix = replicate("  ", depth);

		// if (!fileLevel) { f.writeln(prefix, "[ ... ]"); continue; }

		f.write(
			prefix,
			"[",
			e.noRemove ? "!" : "",
			e.dead ? "X" : "",
		);
		if (e.children.length == 0)
		{
			f.write(
				" ",
				e.redirect ? "-> " ~ text(findEntityEx(root, e.redirect).entity.id) ~ " " : "",
				e.isFile ? e.filename ? printableFN(e.filename) ~ " " : null : e.head ? printable(e.head) ~ " " : null,
				e.tail ? printable(e.tail) ~ " " : null,
				e.comment ? "/* " ~ e.comment ~ " */ " : null,
				"]"
			);
		}
		else
		{
			f.writeln(e.comment ? " // " ~ e.comment : null);
			if (e.isFile) f.writeln(prefix, "  ", printableFN(e.filename));
			if (e.head) f.writeln(prefix, "  ", printable(e.head));
			foreach (c; e.children)
				print(c, depth+1);
			if (e.tail) f.writeln(prefix, "  ", printable(e.tail));
			f.write(prefix, "]");
		}
		if (e.dependents.length || e.id in redirects || trace)
			f.write(" =", e.id);
		if (e.id in dependencies)
		{
			f.write(" =>");
			foreach (d; dependencies[e.id])
				f.write(" ", d);
		}
		f.writeln();
	}

	print(root, 0);

	f.close();
}

void dumpToHtml(Entity root, string fn)
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

void dumpToJson(Entity root, string fn)
{
	import std.json : JSONValue;

	bool[const(Address)*] needLabel;

	void scan(Entity e, const(Address)* addr)
	{
		foreach (dependent; e.dependents)
		{
			assert(dependent.address);
			needLabel[dependent.address] = true;
		}
		foreach (i, child; e.children)
			scan(child, addr.child(i));
	}
	scan(root, &rootAddress);

	JSONValue toJson(Entity e, const(Address)* addr)
	{
		JSONValue[string] o;

		if (e.isFile)
			o["filename"] = e.filename;

		if (e.head.length)
			o["head"] = e.head;
		if (e.children.length)
			o["children"] = e.children.length.iota.map!(i =>
				toJson(e.children[i], addr.child(i))
			).array;
		if (e.tail.length)
			o["tail"] = e.tail;

		if (e.noRemove)
			o["noRemove"] = true;

		if (addr in needLabel)
			o["label"] = e.id.to!string;
		if (e.dependents.length)
			o["dependents"] = e.dependents.map!((ref dependent) =>
				root.findEntity(dependent.address).entity.id.to!string
			).array;

		return JSONValue(o);
	}

	auto jsonDoc = JSONValue([
		"version" : JSONValue(1),
		"root" : toJson(root, &rootAddress),
	]);

	std.file.write(fn, jsonDoc.toPrettyString());
}

// void dumpText(string fn, ref Reduction r = nullReduction)
// {
// 	auto f = File(fn, "wt");
// 	dump(root, r, (string) {}, &f.write!string);
// 	f.close();
// }

version(testsuite)
shared static this()
{
	import core.runtime;
	"../../cov".mkdir.collectException();
	dmd_coverDestPath("../../cov");
	dmd_coverSetMerge(true);
}
