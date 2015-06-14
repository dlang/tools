/*
 *  Copyright (C) 2008 by Andrei Alexandrescu
 *  Written by Andrei Alexandrescu, www.erdani.org
 *  Based on an idea by Georg Wrede
 *  Featuring improvements suggested by Christopher Wright
 *  Windows port using bug fixes and suggestions by Adam Ruppe
 *
 *
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */

// Written in the D programming language.

import std.algorithm, std.array, core.stdc.stdlib, std.datetime,
    std.digest.md, std.exception, std.file, std.getopt,
    std.parallelism, std.path, std.process, std.range, std.regex,
    std.stdio, std.string, std.typetuple;

version (Posix)
{
    enum objExt = ".o";
    enum binExt = "";
    enum libExt = ".a";
    enum altDirSeparator = "";
}
else version (Windows)
{
    enum objExt = ".obj";
    enum binExt = ".exe";
    enum libExt = ".lib";
    enum altDirSeparator = "/";
}
else
{
    static assert(0, "Unsupported operating system.");
}

private bool chatty, buildOnly, dryRun, force, preserveOutputPaths;
private string exe;
private string[] exclusions = ["std", "etc", "core"]; // packages that are to be excluded
private string[] extraFiles = [];

version (DigitalMars)
    private enum defaultCompiler = "dmd";
else version (GNU)
    private enum defaultCompiler = "gdmd";
else version (LDC)
    private enum defaultCompiler = "ldmd2";
else
    static assert(false, "Unknown compiler");

private string compiler = defaultCompiler;

int main(string[] args)
{
    //writeln("Invoked with: ", args);
    if (args.length > 1 && args[1].startsWith("--shebang ", "--shebang="))
    {
        // multiple options wrapped in one
        auto a = args[1]["--shebang ".length .. $];
        args = args[0 .. 1] ~ std.string.split(a) ~ args[2 .. $];
    }

    // Continue parsing the command line; now get rdmd's own arguments

    // Parse the -o option (-ofmyfile or -odmydir).
    void dashOh(string key, string value)
    {
        if (value[0] == 'f')
        {
            // -ofmyfile passed
            exe = value[1 .. $];
        }
        else if (value[0] == 'd')
        {
            // -odmydir passed
            if (!exe.ptr) // Don't let -od override -of
            {
                // add a trailing dir separator to clarify it's a dir
                exe = value[1 .. $];
                if (!exe.endsWith(dirSeparator))
                {
                    exe ~= dirSeparator;
                }
                assert(exe.endsWith(dirSeparator));
            }
        }
        else if (value[0] == '-')
        {
            // -o- passed
            enforce(false, "Option -o- currently not supported by rdmd");
        }
        else if (value[0] == 'p')
        {
            // -op passed
            preserveOutputPaths = true;
        }
        else
        {
            enforce(false, "Unrecognized option: "~key~value);
        }
    }

    // start the web browser on documentation page
    void man()
    {
        std.process.browse("http://dlang.org/rdmd.html");
    }

    auto programPos = indexOfProgram(args);
    assert(programPos > 0);
    auto argsBeforeProgram = args[0 .. programPos];

    bool bailout;    // bailout set by functions called in getopt if
                     // program should exit
    string[] loop;       // set by --loop
    bool addStubMain;// set by --main
    string[] eval;     // set by --eval
    bool makeDepend;
    string makeDepFile;
    getopt(argsBeforeProgram,
            std.getopt.config.caseSensitive,
            std.getopt.config.passThrough,
            "build-only", &buildOnly,
            "chatty", &chatty,
            "compiler", &compiler,
            "dry-run", &dryRun,
            "eval", &eval,
            "loop", &loop,
            "exclude", &exclusions,
            "extra-file", &extraFiles,
            "force", &force,
            "help", { writeln(helpString); bailout = true; },
            "main", &addStubMain,
            "makedepend", &makeDepend,
            "makedepfile", &makeDepFile,
            "man", { man(); bailout = true; },
            "o", &dashOh);
    if (bailout) return 0;
    if (dryRun) chatty = true; // dry-run implies chatty

    /* Only -of is supported because Make is very susceptible to file names, and
     * it doesn't do a good job resolving them. One option would be to use
     * std.path.buildNormalizedPath(), but some corner cases will break, so it
     * has been decided to only allow -of for now.
     * To see the full discussion please refer to:
     * https://github.com/D-Programming-Language/tools/pull/122
     */
    if ((makeDepend || makeDepFile.ptr) && (!exe.ptr || exe.endsWith(dirSeparator)))
    {
        stderr.write(helpString);
        stderr.writeln();
        stderr.writeln("Missing option: --makedepend and --makedepfile need -of");
        return 1;
    }

    // Validate extensions of extra files (--extra-file)
    foreach (immutable f; extraFiles)
    {
        if (![".d", ".di", objExt].canFind(f.extension))
        {
            stderr.writeln("Bad value for --extra-file: \"" ~ f ~ "\". " ~
                "Value must be a D source file (extension .d or .di) " ~
                "or an object file (extension " ~ objExt ~ ").");
            return 1;
        }
    }

    if (preserveOutputPaths)
    {
        argsBeforeProgram = argsBeforeProgram[0] ~ ["-op"] ~ argsBeforeProgram[1 .. $];
    }

    string root;
    string[] programArgs;
    // Just evaluate this program!
    enforce(!(loop.ptr && eval.ptr), "Cannot mix --eval and --loop.");
    if (loop.ptr)
    {
        enforce(programPos == args.length, "Cannot have both --loop and a " ~
                "program file ('" ~ args[programPos] ~ "').");
        root = makeEvalFile(importWorld ~ "void main(char[][] args) { "
                ~ "foreach (line; std.stdio.stdin.byLine()) {\n"
                ~ std.string.join(loop, "\n")
                ~ ";\n} }");
    }
    else if (eval.ptr)
    {
        enforce(programPos == args.length, "Cannot have both --eval and a " ~
                "program file ('" ~ args[programPos] ~ "').");
        root = makeEvalFile(importWorld ~ "void main(char[][] args) {\n"
                ~ std.string.join(eval, "\n") ~ ";\n}");
    }
    else if (programPos < args.length)
    {
        root = args[programPos].chomp(".d") ~ ".d";
        programArgs = args[programPos + 1 .. $];
    }
    else // no code to run
    {
        write(helpString);
        return 1;
    }

    auto
        exeBasename = root.baseName(".d"),
        exeDirname = root.dirName;

    assert(argsBeforeProgram.length >= 1);
    auto compilerFlags = argsBeforeProgram[1 .. $];

    bool lib = compilerFlags.canFind("-lib");
    string outExt = lib ? libExt : binExt;

    // -lib implies --build-only. Can't run a library.
    if (lib) buildOnly = true;

    // --build-only implies the user would like a binary in the program's directory
    if (buildOnly && !exe.ptr)
        exe = exeDirname ~ dirSeparator;

    if (exe.ptr && exe.endsWith(dirSeparator))
    {
        // user specified a directory, complete it to a file
        exe = buildPath(exe, exeBasename) ~ outExt;
    }

    immutable workDir = getWorkPath(root, compilerFlags);
    lockWorkPath(workDir); // will be released by the OS on process exit

    /* Replicating the whole path of the source directory into objDirBase.
    Setting -od to the deep end of that. Transforming all source paths to
    relative paths. Using -op. This way, the object files all end up in
    objDirBase.

    With a shallow -od and without -op there would be object file conflicts.
    With a shallow -od and with -op the object files could end up all over the
    file system.

    -oq as described in issue 3541 (fully qualified module name as object
    filename) would be a candidate to simplify this. However, getting the fully
    qualified module name of an --extra-file would be an undertaking itself.
    */
    string objDirBase = buildPath(workDir, "objs2");
    string objDir = buildPath(objDirBase, getcwd().relativePath("/"));

    yap("mkdirRecurse ", objDir);
    if (!dryRun)
        mkdirRecurse(objDir);

    compilerFlags ~= "-I" ~ dirName(root);

    /*
      We need to be careful about using -o. Normally the generated
      executable is hidden in the unique directory workDir. But if the
      user forces generation in a specific place by using -od or -of,
      the time of the binary can't be used to check for freshness
      because the user may change e.g. the compile option from one run
      to the next, yet the generated binary's datetime stays the
      same. In those cases, we'll use a dedicated file called ".built"
      and placed in workDir. Upon a successful build, ".built" will be
      touched. See also
      http://d.puremagic.com/issues/show_bug.cgi?id=4814
     */
    string buildWitness;
    SysTime lastBuildTime = SysTime.min;
    if (exe.ptr)
    {
        // user-specified exe name
        buildWitness = buildPath(workDir, ".built");
        if (!exe.newerThan(buildWitness))
        {
            // Both exe and buildWitness exist, and exe is older than
            // buildWitness. This is the only situation in which we
            // may NOT need to recompile.
            yap("stat ", buildWitness);
            lastBuildTime = buildWitness.timeLastModified(SysTime.min);
        }
    }
    else
    {
        exe = buildPath(workDir, exeBasename) ~ outExt;
        buildWitness = exe;
        yap("stat ", buildWitness);
        lastBuildTime = buildWitness.timeLastModified(SysTime.min);
    }

    // Fetch dependencies
    const HashSet!DepNode[DepNode] myDeps = getDependencies(root, workDir,
        compilerFlags, addStubMain);

    // --makedepend mode. Just print dependencies and exit.
    if (makeDepend)
    {
        writeDeps(exe, root, myDeps, stdout);
        return 0;
    }

    // --makedepfile mode. Print dependencies to a file and continue.
    // This is similar to GCC's -MF option, very useful to update the
    // dependencies file and compile in one go:
    // -include .deps.mak
    // prog:
    //      rdmd --makedepfile=.deps.mak --build-only prog.d
    if (makeDepFile !is null)
        writeDeps(exe, root, myDeps, File(makeDepFile, "w"));

    string d2obj(string dfile)
    {
        return buildPath(objDir, dfile.relativePath).setExtension(objExt);
    }

    /*
    Put together file arguments for the compile and link commands.
    For source files, decide if to (re-)compile or if to reuse an existing
    object file.
    Also pick out the libraries. They need to be passed explicitly in the
    link command.
    */
    const SysTime[string] times = !force ? getTimes(myDeps) :
        (SysTime[string]).init;
    HashSet!string toCompile;
    HashSet!string toReuse;
    HashSet!string libraries;
    foreach (node; myDeps.byKey)
    {
        final switch (node.type)
        {
            case DepNode.Type.source:
            immutable o = d2obj(node.file);
            if (force || times[node.file].newerThan(o))
                toCompile.insert(node.file);
            else toReuse.insert(o);
            break;

            case DepNode.Type.object: toReuse.insert(node.file); break;
            case DepNode.Type.other: break;

            case DepNode.Type.library:
            if (node.file != exe) libraries.insert(node.name);
            break;
        }
    }

    // compile
    if (!toCompile[].empty)
    {
        immutable int r = compile(toCompile[].map!relativePath.array,
            compilerFlags, objDir, workDir);
        if (r) return r;
    }

    // link
    if (force || times[exe] > lastBuildTime)
    {
        const string[] objects = chain(toCompile[].map!d2obj, toReuse[]).array;
        const string[] libFlags = libraries[].map!(lib => "-L-l" ~ lib).array;
        if (int r = link(exe, objects, compilerFlags ~ libFlags, workDir))
            return r;

        // Touch the build witness to track the build time
        if (buildWitness != exe)
        {
            yap("touch ", buildWitness);
            if (!dryRun)
                std.file.write(buildWitness, "");
        }
    }

    if (buildOnly)
    {
        // Pretty much done!
        return 0;
    }

    // release lock on workDir before launching the user's program
    unlockWorkPath();

    // run
    return exec(exe ~ programArgs);
}

size_t indexOfProgram(string[] args)
{
    foreach(i, arg; args[1 .. $])
    {
        if (!arg.startsWith('-', '@') &&
                !arg.endsWith(".obj", ".o", ".lib", ".a", ".def", ".map", ".res"))
        {
            return i + 1;
        }
    }

    return args.length;
}

void writeDeps(string exe, string root, in HashSet!DepNode[DepNode] myDeps,
    File fo)
{
     fo.writeln(exe, ": \\");
     fo.write(" ", root);
     foreach (node, _; myDeps)
     {
         if(node.file == exe || node.file == root) continue;
         fo.writeln(" \\");
         fo.write(" ", node.file);
     }
     fo.writeln();
     fo.writeln();
     fo.writeln(root, ":");
     foreach (node, _; myDeps)
     {
         if(node.file == exe || node.file == root) continue;
         fo.writeln('\n', node.file, ":");
     }
}

bool inALibrary(string module_, string file)
{
    if (file.endsWith(".di")
            || module_ == "object" || module_ == "gcstats")
        return true;

    foreach(string exclusion; exclusions)
        if (module_.startsWith(exclusion~'.'))
            return true;

    return false;
}

private @property string myOwnTmpDir()
{
    auto tmpRoot = tempDir();
    version (Posix)
    {
        import core.sys.posix.unistd;
        tmpRoot = buildPath(tmpRoot, ".rdmd-%d".format(getuid()));
    }
    else
        tmpRoot = tmpRoot.replace("/", dirSeparator).buildPath(".rdmd");

    yap("mkdirRecurse ", tmpRoot);
    if (!dryRun)
        mkdirRecurse(tmpRoot);
    return tmpRoot;
}

private string getWorkPath(in string root, in string[] compilerFlags)
{
    static string workPath;
    if (workPath.ptr)
        return workPath;

    enum string[] irrelevantSwitches = [
        "--help", "-ignore", "-quiet", "-v" ];

    MD5 context;
    context.start();
    context.put(root.absolutePath().representation);
    foreach (flag; compilerFlags)
    {
        if (irrelevantSwitches.canFind(flag)) continue;
        context.put(flag.representation);
    }
    auto digest = context.finish();
    string hash = toHexString(digest);

    const tmpRoot = myOwnTmpDir;
    workPath = buildPath(tmpRoot,
            "rdmd-" ~ baseName(root) ~ '-' ~ hash);

    yap("mkdirRecurse ", workPath);
    if (!dryRun)
        mkdirRecurse(workPath);

    return workPath;
}

private File lockFile;

private void lockWorkPath(string workPath)
{
    string lockFileName = buildPath(workPath, "rdmd.lock");
    if (!dryRun) lockFile.open(lockFileName, "w");
    yap("lock ", lockFile.name);
    if (!dryRun) lockFile.lock();
}

private void unlockWorkPath()
{
    yap("unlock ", lockFile.name);
    if (!dryRun)
    {
        lockFile.unlock();
        lockFile.close();
    }
}

private int compile(in string[] sources, string[] compilerFlags,
    in string objDir, in string workDir)
{
    // Don't pass -lib to the compiler here.
    compilerFlags = compilerFlags.filter!(flag => flag != "-lib").array();

    return runCompiler(["-c", "-od" ~ objDir, "-op"] ~ compilerFlags ~ sources,
        workDir);
}

private int link(string fullExe, in string[] objects, in string[] compilerFlags,
    in string workDir)
{
    version (Windows)
        fullExe = fullExe.defaultExtension(".exe");

    // Delete the old executable before we start building.
    yap("stat ", fullExe);
    if (exists(fullExe))
    {
        enforce(!isDir(fullExe), fullExe ~ " is a directory");
        yap("rm ", fullExe);
        if (!dryRun)
        {
            try
                   remove(fullExe);
            catch (FileException e)
            {
                // This can occur on Windows if the executable is locked.
                // Although we can't delete the file, we can still rename it.
                auto oldExe = "%s.%s-%s.old".format(fullExe,
                    Clock.currTime.stdTime, thisProcessID);
                yap("mv ", fullExe, " ", oldExe);
                rename(fullExe, oldExe);
            }
        }
    }

    auto fullExeTemp = fullExe ~ ".tmp";
    immutable result = runCompiler(
        ["-of" ~ fullExeTemp] ~ objects ~ compilerFlags,
        workDir);
    if (result)
    {
        // build failed
        if (exists(fullExeTemp))
            remove(fullExeTemp);
        return result;
    }
    if (!dryRun) rename(fullExeTemp, fullExe);
    return result;
}

private int runCompiler(string[] todo, in string workDir)
{
    // Different shells and OS functions have different limits,
    // but 1024 seems to be the smallest maximum outside of MS-DOS.
    enum maxLength = 1024;
    auto commandLength = escapeShellCommand(todo).length;
    if (commandLength + compiler.length >= maxLength)
    {
        auto rspName = buildPath(workDir, "rdmd.rsp");

        // DMD uses Windows-style command-line parsing in response files
        // regardless of the operating system it's running on.
        std.file.write(rspName, array(map!escapeWindowsArgument(todo)).join(" "));

        todo = [ "@"~rspName ];
    }

    return run([ compiler ] ~ todo);
}

// Run a program optionally writing the command line first
// If "replace" is true and the OS supports it, replace the current process.

private int run(string[] args, string output = null, bool replace = false)
{
    import std.conv;
    yap(replace ? "exec " : "spawn ", format("%(%s %)", args));
    if (dryRun) return 0;

    if (replace && !output.ptr)
    {
        version (Windows)
            { /* Windows doesn't have exec, fall back to spawnProcess+wait */ }
        else
        {
            import std.c.process;
            auto argv = args.map!toStringz.chain(null.only).array;
            return execv(argv[0], argv.ptr);
        }
    }

    File outputFile;
    if (output.ptr)
        outputFile = File(output, "wb");
    else
        outputFile = stdout;
    auto process = spawnProcess(args, stdin, outputFile);
    return process.wait();
}

private int exec(string[] args)
{
    return run(args, null, true);
}

/*
Get all dependencies of rootModule.
Returns a mapping of entitites to other entitites that depend on them.
The mapping is mainly obtained by running dmd -deps against rootModule.
It also includes nodes for the build target (exe), the compiler binary,
the compiler config file, extra files from --extra-file, and any stub main file
from --main.

Example:

File "root.d":
----
import foo;
pragma(lib, "bar");
----

File "foo.d":
----
enum e = import("baz");
----

Result of `getDependencies("root.d", ...)`:
[
    DepNode.other("root"): [],
    DepNode.source("root.d"): [root],
    DepNode.source("foo.d"): [DepNode.source("root.d")],
    DepNode.other("baz"): [DepNode.source("foo.d")],
    DepNode.library("bar", ""): [DepNode.source("root.d")],
    DepNode.other("dmd"): [... all source nodes ...],
    DepNode.other("dmd.conf"): [... all source nodes ...],
]
*/
private HashSet!DepNode[DepNode] getDependencies(string rootModule,
        string workDir, string[] compilerFlags, bool addStubMain)
{
    immutable depsFilename = buildPath(workDir, "rdmd.deps2");

    HashSet!DepNode[DepNode] readDepsFile()
    {
        string findLib(string libName)
        {
            // This can't be 100% precise without knowing exactly where the linker
            // will look for libraries (which requires, but is not limited to,
            // parsing the linker's command line (as specified in dmd.conf/sc.ini).
            // Go for best-effort instead.
            string[] dirs = ["."];
            foreach (envVar; ["LIB", "LIBRARY_PATH", "LD_LIBRARY_PATH"])
                dirs ~= environment.get(envVar, "").split(pathSeparator);
            version (Windows)
                string[] names = [libName ~ ".lib"];
            else
            {
                string[] names = ["lib" ~ libName ~ ".a", "lib" ~ libName ~ ".so"];
                dirs ~= ["/lib", "/usr/lib"];
            }
            foreach (dir; dirs)
                foreach (name; names)
                {
                    auto path = buildPath(dir, name);
                    if (path.exists)
                        return absolutePath(path);
                }
            return null;
        }
        yap("read ", depsFilename);
        auto depsReader = File(depsFilename);
        scope(exit) collectException(depsReader.close()); // don't care for errors

        HashSet!DepNode[DepNode] result;

        // Fetch all dependencies and put them into result
        auto pattern = regex(`^deps(Import|File|Lib) ` ~
            `(?P<importing_module>[^ ]+) \((?P<importing_file>[^)]+)\) ` ~
            `: (?:[^ ]+ : )?` ~ // private/public
            `(?P<imported_name>[^ ]+)(?: \((?P<imported_file>[^)]+)\))?$`);
        foreach (string line; depsReader.byLineCopy)
        {
            auto regexMatch = matchFirst(line, pattern);
            if (regexMatch.empty) continue;

            immutable importingModule = regexMatch["importing_module"].strip();
            immutable importingFile = regexMatch["importing_file"].strip();
            immutable importedName = regexMatch["imported_name"].strip();
            immutable importedFile = regexMatch["imported_file"].strip();

            // Don't care about dependencies of libraries.
            if (inALibrary(importingModule, importingFile)) continue;

            auto importingNode = DepNode.source(importingFile);
            result.lookupOrInit(importingNode);

            switch(regexMatch[1])
            {
            case "Import":
                if (!inALibrary(importedName, importedFile))
                {
                    auto node = DepNode.source(importedFile);
                    result.lookupOrInit(node).insert(importingNode);
                }
                break;

            case "File":
                auto node = DepNode.other(importedFile);
                result.lookupOrInit(node).insert(importingNode);
                break;

            case "Lib":
                DepNode node = DepNode.library(importedName,
                    findLib(importedName));
                if (node.file.ptr)
                    yap("library ", node.name, " ", node.file);
                result.lookupOrInit(node).insert(importingNode);
                break;

            default: assert(0);
            }
        }

        return result;
    }

    HashSet!DepNode[DepNode] deps;
    bool generateDepsFile = true;

    // Check if the old dependency file is fine
    if (!force)
    {
        yap("stat ", depsFilename);
        auto depsT = depsFilename.timeLastModified(SysTime.min);
        if (depsT > SysTime.min)
        {
            // See if the deps file is still in good shape
            deps = readDepsFile();
            auto allDeps = deps.byKey
                .map!(node => node.file)
                .filter!(f => f != "")
                .array;
            bool mustRebuildDeps = allDeps.anyNewerThan(depsT);
            if (!mustRebuildDeps)
            {
                // Cool, we're in good shape
                generateDepsFile = false;
            }
        }
    }

    if (generateDepsFile)
    {
        // Don't pass -lib to the compiler here.
        compilerFlags = compilerFlags.filter!(flag => flag != "-lib").array();

        // Collect dependencies
        auto depsGetter =
            [ compiler ] ~ compilerFlags ~
            ["-deps", "-o-", rootModule];

        scope(failure)
        {
            // Delete the deps file on failure, we don't want to be fooled
            // by it next time we try
            collectException(std.file.remove(depsFilename));
        }

        immutable depsExitCode = run(depsGetter, depsFilename);
        if (depsExitCode)
        {
            stderr.writefln("Failed: %(%s %)", depsGetter);
            collectException(std.file.remove(depsFilename));
            exit(depsExitCode);
        }

        if (!dryRun) deps = readDepsFile();
    }

    // Add exe as the root of the dependency graph.
    auto exeNode = DepNode.other(exe);
    deps[exeNode] = HashSet!DepNode();
    deps.lookupOrInit(DepNode.source(rootModule)).insert(exeNode);
        /* Reading the deps file above did make an entry for the root module,
        but it may have used a different path to the same file.
        This is why lookupOrInit is here.
        Ideally, there should be only one entry per file. But one extra
        entry isn't so bad, I suppose. */

    // All dependencies specified through --extra-file
    foreach (immutable f; extraFiles)
    {
        DepNode extraNode;
        switch (f.extension)
        {
            case ".d": case ".di": extraNode = DepNode.source(f); break;
            case objExt: extraNode = DepNode.object(f); break;
            default: assert(false);
        }
        deps.lookupOrInit(extraNode).insert(exeNode);
    }

    // Need to add void main(){}?
    if (addStubMain)
    {
        auto stubMain = buildPath(myOwnTmpDir, "stubmain.d");
        std.file.write(stubMain, "void main(){}");
        deps.lookupOrInit(DepNode.source(stubMain)).insert(exeNode);
    }

    // add compiler binary and config file as dependencies to all source files

    void addDepenencyToAllSourceFiles(DepNode dependency)
    {
        deps.lookupOrInit(dependency);
        foreach (dependent; deps.byKey)
        {
            if (dependent.type == DepNode.Type.source)
                deps[dependency].insert(dependent);
        }
    }

    // binary
    immutable binaryNode = DepNode.other(which(compiler));
    deps.lookupOrInit(binaryNode);
    addDepenencyToAllSourceFiles(binaryNode);

    // config file
    {
        immutable cmd = [compiler, "--help"];
        auto pipes = pipeProcess(cmd);

        auto pattern = regex(`^Config file: (.*)$`);
        foreach (line; pipes.stdout.byLineCopy)
        {
            auto m = line.matchFirst(pattern);
            if (m)
            {
                immutable confFile = m[1].strip;
                // The config file is special: if missing, that's fine too. So
                // add it as a dependency only if it actually exists.
                if (confFile.exists)
                {
                    addDepenencyToAllSourceFiles(DepNode.other(m[1]));
                }
                break;
            }
        }

        if (int status = wait(pipes.pid))
        {
            stderr.writefln("Failed: %(%s %)", cmd);
            exit(status);
        }
    }

    return deps;
}

struct DepNode
{
    enum Type {source, object, other, library}
    Type type;

    string file; // may be missing with type == library; must be set otherwise
    string name; // must be set when type == library; must not be set otherwise

    this(Type type, string file, string name)
    {
        this.type = type;
        this.file = file;
        this.name = name;
    }

    invariant()
    {
        if (type == Type.library) assert(name != "");
        else
        {
            assert(name == "");
            assert(file != "");
        }
    }

    static DepNode source(string file) {return DepNode(Type.source, file, "");}
    static DepNode object(string file) {return DepNode(Type.object, file, "");}
    static DepNode other(string file) {return DepNode(Type.other, file, "");}
    static DepNode library(string name, string file)
    {
        return DepNode(Type.library, file, name);
    }
}

/* Get the relevant modification times for all files in 'dependencies'.
The relevant time for a file is the maximum of its own time and the times of
all files it depends on. */
SysTime[string] getTimes(const HashSet!DepNode[DepNode] dependencies)
{
    SysTime[string] times;
    /* Update the times of 'node' and all nodes that depend on it to t, if t is
    greater than the currently stored time. */
    void updateTimes(DepNode node, SysTime t)
    {
        /* No associated file? Then don't add to 'times'. And without a file,
        this can't depend on anything. Which means this can only be a root call
        (t = SysTime.min). So there's no point in propagating t upwards.
        Nothing to do. */
        if (node.file == "")
        {
            assert(t == SysTime.min); // root call
            return;
        }

        /* If there's a time stored and it's newer than or equal to t, then
        there's nothing to do here. */
        if ((node.file in times) !is null && times[node.file] >= t) return;

        if ((node.file in times) is null)
            times[node.file] = timeLastModified(node.file, SysTime.min);
        if (t > times[node.file])
            times[node.file] = t;

        // Update the times of all dependent nodes, too.
        if (times[node.file] > SysTime.min)
        {
            foreach (dependent; dependencies.get(node, HashSet!DepNode.init)[])
                updateTimes(dependent, times[node.file]);
        }
    }

    /* Sort nodes by modification time, descending. Processing them in this
    order guarantees that the same path isn't updated more than once. */
    const DepNode[] nodesByTime = dependencies.byKey.array
        .sort!((a, b) =>
            // Not newerThan because that's not antisymmetric as sort requires.
            timeLastModified(a.file, SysTime.min) >
            timeLastModified(b.file, SysTime.min)
        )
        .release;

    foreach (node; nodesByTime) updateTimes(node, SysTime.min);
    return times;
}

// Is any file newer than the given file?
bool anyNewerThan(in string[] files, in string file)
{
    yap("stat ", file);
    return files.anyNewerThan(file.timeLastModified);
}

// Is any file newer than the given file?
bool anyNewerThan(in string[] files, SysTime t)
{
    // Experimental: running newerThan in separate threads, one per file
    if (false)
    {
        foreach (source; files)
        {
            if (source.newerThan(t))
            {
                return true;
            }
        }
        return false;
    }
    else
    {
        bool result;
        foreach (source; taskPool.parallel(files))
        {
            yap("stat ", source);
            if (!result && source.newerThan(t))
            {
                result = true;
            }
        }
        return result;
    }
}

/*
If force is true, returns true. Otherwise, if source and target both
exist, returns true iff source's timeLastModified is strictly greater
than target's. Otherwise, returns true.
 */
private bool newerThan(string source, string target)
{
    if (force) return true;
    yap("stat ", target);
    return source.newerThan(target.timeLastModified(SysTime.min));
}

private bool newerThan(string source, SysTime target)
{
    if (force) return true;
    try
    {
        yap("stat ", source);
        return DirEntry(source).timeLastModified > target;
    }
    catch (Exception)
    {
        // File not there, consider it newer
        return true;
    }
}

private bool newerThan(SysTime source, string target)
{
    if (force) return true;
    yap("stat ", target);
    return source > target.timeLastModified(SysTime.min);
}

private @property string helpString()
{
    return
"rdmd build "~thisVersion~"
Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]...
Builds (with dependents) and runs a D program.
Example: rdmd -release myprog --myprogparm 5

Any option to be passed to the compiler must occur before the program name. In
addition to compiler options, rdmd recognizes the following options:
  --build-only       just build the executable, don't run it
  --chatty           write compiler commands to stdout before executing them
  --compiler=comp    use the specified compiler (e.g. gdmd) instead of %s
  --dry-run          do not compile, just show what commands would be run
                      (implies --chatty)
  --eval=code        evaluate code as in perl -e (multiple --eval allowed)
  --exclude=package  exclude a package from the build (multiple --exclude allowed)
  --extra-file=file  include an extra source or object in the compilation
                     (multiple --extra-file allowed)
  --force            force a rebuild even if apparently not necessary
  --help             this message
  --loop             assume \"foreach (line; stdin.byLine()) { ... }\" for eval
  --main             add a stub main program to the mix (e.g. for unittesting)
  --makedepend       print dependencies in makefile format and exit
                     (needs dmd's option `-of` to be present)
  --makedepfile=file print dependencies in makefile format to file and continue
                     (needs dmd's option `-of` to be present)
  --man              open web browser on manual page
  --shebang          rdmd is in a shebang line (put as first argument)
".format(defaultCompiler);
}

// For --eval
immutable string importWorld = "
module temporary;
import std.stdio, std.algorithm, std.array, std.ascii, std.base64,
    std.bigint, std.bitmanip,
    std.compiler, std.complex, std.concurrency, std.container, std.conv,
    std.cstream, std.csv,
    std.datetime, std.demangle, std.digest.md, std.encoding, std.exception,
    std.file,
    std.format, std.functional, std.getopt, std.json,
    std.math, std.mathspecial, std.mmfile,
    std.numeric, std.outbuffer, std.parallelism, std.path, std.process,
    std.random, std.range, std.regex, std.signals, std.socket,
    std.socketstream, std.stdint, std.stdio, std.stdiobase, std.stream,
    std.string, std.syserror, std.system, std.traits, std.typecons,
    std.typetuple, std.uni, std.uri, std.utf, std.variant, std.xml, std.zip,
    std.zlib;
";

string makeEvalFile(string todo)
{
    auto pathname = myOwnTmpDir;
    auto srcfile = buildPath(pathname,
            "eval." ~ todo.md5Of.toHexString ~ ".d");

    if (force || !exists(srcfile))
    {
        std.file.write(srcfile, todo);
    }

    // Clean pathname
    enum lifetimeInHours = 24;
    auto cutoff = Clock.currTime() - dur!"hours"(lifetimeInHours);
    yap("dirEntries ", pathname);
    foreach (DirEntry d; dirEntries(pathname, SpanMode.shallow))
    {
        yap("stat ", d.name);
        if (d.timeLastModified < cutoff)
        {
            collectException(std.file.remove(d.name));
            //break; // only one per call so we don't waste time
        }
    }

    return srcfile;
}

@property string thisVersion()
{
    enum d = __DATE__;
    enum month = d[0 .. 3],
        day = d[4] == ' ' ? "0"~d[5] : d[4 .. 6],
        year = d[7 .. $];
    enum monthNum
        = month == "Jan" ? "01"
        : month == "Feb" ? "02"
        : month == "Mar" ? "03"
        : month == "Apr" ? "04"
        : month == "May" ? "05"
        : month == "Jun" ? "06"
        : month == "Jul" ? "07"
        : month == "Aug" ? "08"
        : month == "Sep" ? "09"
        : month == "Oct" ? "10"
        : month == "Nov" ? "11"
        : month == "Dec" ? "12"
        : "";
    static assert(month != "", "Unknown month "~month);
    return year[0]~year[1 .. $]~monthNum~day;
}

string which(string path)
{
    yap("which ", path);
    if (path.canFind(dirSeparator) || altDirSeparator != "" && path.canFind(altDirSeparator)) return path;
    string[] extensions = [""];
    version(Windows) extensions ~= environment["PATHEXT"].split(pathSeparator);
    foreach (extension; extensions)
    {
        foreach (envPath; environment["PATH"].splitter(pathSeparator))
        {
            string absPath = buildPath(envPath, path ~ extension);
            yap("stat ", absPath);
            if (exists(absPath) && isFile(absPath))
                return absPath;
        }
    }
    throw new FileException(path, "File not found in PATH");
}

void yap(size_t line = __LINE__, T...)(auto ref T stuff)
{
    if (!chatty) return;
    debug stderr.writeln(line, ": ", stuff);
    else stderr.writeln(stuff);
}

private struct HashSet(T) // quick implementation abusing an associative array
{
    private bool[T] aa;
    this(T[] values ...) {foreach (v; values) insert(v);}
    void insert(T thing) {aa[thing] = true;}
    auto opIndex() {return aa.byKey;}
    auto opIndex() const {return aa.byKey;}
    bool contains(T thing) const {return (thing in aa) !is null;}
}

private V* lookupOrInit(K, V)(ref V[K] aa, K key)
{
    V* p = key in aa;
    if (p is null)
    {
        aa[key] = V.init;
        p = key in aa;
    }
    return p;
}
