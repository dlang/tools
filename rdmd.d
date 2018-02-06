#!/usr/bin/env rdmd
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
    std.stdio, std.string, std.typecons, std.typetuple;

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
private string exe, userTempDir;
immutable string[] defaultExclusions = ["std", "etc", "core"];
private string[] exclusions = defaultExclusions; // packages that are to be excluded
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

version(unittest) {} else
int main(string[] args)
{
    //writeln("Invoked with: ", args);
    // Look for the D compiler rdmd invokes automatically in the same directory as rdmd
    // and fall back to using the one in your path otherwise.
    string compilerPath = buildPath(dirName(thisExePath()), defaultCompiler);
    if (Yap.existsAsFile(compilerPath))
        compiler = compilerPath;

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
            enforce(false, "Unrecognized option: " ~ key ~ value);
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
            "include", (string opt, string p) { exclusions = exclusions.filter!(ex => ex != p).array(); },
            "extra-file", &extraFiles,
            "force", &force,
            "help", { writeln(helpString); bailout = true; },
            "main", &addStubMain,
            "makedepend", &makeDepend,
            "makedepfile", &makeDepFile,
            "man", { man(); bailout = true; },
            "tmpdir", &userTempDir,
            "o", &dashOh);
    if (bailout) return 0;
    if (dryRun) chatty = true; // dry-run implies chatty

    /* Only -of is supported because Make is very susceptible to file names, and
     * it doesn't do a good job resolving them. One option would be to use
     * std.path.buildNormalizedPath(), but some corner cases will break, so it
     * has been decided to only allow -of for now.
     * To see the full discussion please refer to:
     * https://github.com/dlang/tools/pull/122
     */
    if ((makeDepend || makeDepFile.ptr) && (!exe.ptr || exe.endsWith(dirSeparator)))
    {
        stderr.write(helpString);
        stderr.writeln();
        stderr.writeln("Missing option: --makedepend and --makedepfile need -of");
        return 1;
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
        root = makeEvalFile(makeEvalCode(loop, Yes.loop));
        argsBeforeProgram ~= "-d";
    }
    else if (eval.ptr)
    {
        enforce(programPos == args.length, "Cannot have both --eval and a " ~
                "program file ('" ~ args[programPos] ~ "').");
        root = makeEvalFile(makeEvalCode(eval, No.loop));
        argsBeforeProgram ~= "-d";
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

    bool obj = compilerFlags.canFind("-c");
    bool lib = compilerFlags.canFind("-lib");
    string outExt = lib ? libExt : obj ? objExt : binExt;

    // Assume --build-only for -c and -lib.
    buildOnly |= obj || lib;

    // --build-only implies the user would like a binary in the program's directory
    if (buildOnly && !exe.ptr)
        exe = exeDirname ~ dirSeparator;

    if (exe.ptr && exe.endsWith(dirSeparator))
    {
        // user specified a directory, complete it to a file
        exe = buildPath(exe, exeBasename) ~ outExt;
    }

    // Compute the object directory and ensure it exists
    immutable workDir = getWorkPath(root, compilerFlags);
    lockWorkPath(workDir); // will be released by the OS on process exit
    string objDir = buildPath(workDir, "objs");
    Yap.mkdirRecurseIfLive(objDir);

    if (lib)
    {
        // When using -lib, the behavior of the DMD -of switch
        // changes: instead of being relative to the current
        // directory, it becomes relative to the output directory.
        // When building libraries, DMD does not generate any object
        // files; thus, we can override objDir (which is normally a
        // temporary directory) to be the current directory, so that
        // the relative -of path becomes correct.
        objDir = ".";
    }

    // Fetch dependencies
    const myDeps = getDependencies(root, workDir, objDir, compilerFlags);

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

    // Compute executable name, check for freshness, rebuild
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
            lastBuildTime = Yap.timeLastModified(buildWitness, SysTime.min);
        }
    }
    else
    {
        exe = buildPath(workDir, exeBasename) ~ outExt;
        buildWitness = exe;
        lastBuildTime = Yap.timeLastModified(buildWitness, SysTime.min);
    }

    // Have at it
    if (chain(root.only, myDeps.byKey).anyNewerThan(lastBuildTime))
    {
        immutable result = rebuild(root, exe, workDir, objDir,
                                   myDeps, compilerFlags, addStubMain);
        if (result)
            return result;

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

void writeDeps(string exe, string root, in string[string] myDeps, File fo)
{
    fo.writeln(exe, ": \\");
    fo.write(" ", root);
    foreach (mod, _; myDeps)
    {
        fo.writeln(" \\");
        fo.write(" ", mod);
    }
    fo.writeln();
    fo.writeln();
    fo.writeln(root, ":");
    foreach (mod, _; myDeps)
    {
        fo.writeln('\n', mod, ":");
    }
}

bool inALibrary(string source, string object)
{
    if (object.endsWith(".di")
            || source == "object" || source == "gcstats")
        return true;

    foreach(string exclusion; exclusions)
        if (source.startsWith(exclusion ~ '.'))
            return true;

    return false;

    // another crude heuristic: if a module's path is absolute, it's
    // considered to be compiled in a separate library. Otherwise,
    // it's a source module.
    //return isabs(mod);
}

private @property string myOwnTmpDir()
{
    auto tmpRoot = userTempDir ? userTempDir : tempDir();
    version (Posix)
    {
        import core.sys.posix.unistd;
        tmpRoot = buildPath(tmpRoot, ".rdmd-%d".format(getuid()));
    }
    else
        tmpRoot = tmpRoot.replace("/", dirSeparator).buildPath(".rdmd");

    Yap.mkdirRecurseIfLive(tmpRoot);
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
    context.put(compiler.representation);
    context.put(root.absolutePath().representation);
    foreach (flag; compilerFlags)
    {
        if (irrelevantSwitches.canFind(flag)) continue;
        context.put(flag.representation);
    }
    foreach (f; extraFiles) context.put(f.representation);
    auto digest = context.finish();
    auto hash = toHexString(digest);

    const tmpRoot = myOwnTmpDir;
    workPath = buildPath(tmpRoot,
            "rdmd-" ~ baseName(root) ~ '-' ~ hash);

    Yap.mkdirRecurseIfLive(workPath);

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

// Rebuild the executable fullExe starting from modules in myDeps
// passing the compiler flags compilerFlags. Generates one large
// object file.

private int rebuild(string root, string fullExe,
        string workDir, string objDir, in string[string] myDeps,
        string[] compilerFlags, bool addStubMain)
{
    version (Windows)
        fullExe = fullExe.defaultExtension(".exe");

    // Delete the old executable before we start building.
    auto fullExeAttributes = Yap.getFileAttributes(fullExe);
    if (fullExeAttributes.exists)
    {
        enforce(fullExeAttributes.isFile, fullExe ~ " is not a regular file");
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
                Yap.rename(fullExe, oldExe);
            }
        }
    }

    auto fullExeTemp = fullExe ~ ".tmp";

    string[] buildTodo()
    {
        auto todo = compilerFlags
            ~ [ "-of" ~ fullExeTemp ]
            ~ [ "-od" ~ objDir ]
            ~ [ "-I" ~ dirName(root) ]
            ~ [ root ];
        foreach (k, objectFile; myDeps) {
            if(objectFile !is null)
                todo ~= [ k ];
        }
        // Need to add void main(){}?
        if (addStubMain)
        {
            auto stubMain = buildPath(myOwnTmpDir, "stubmain.d");
            std.file.write(stubMain, "void main(){}");
            todo ~= [ stubMain ];
        }
        return todo;
    }
    auto todo = buildTodo();

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

        todo = [ "@" ~ rspName ];
    }

    immutable result = run([ compiler ] ~ todo);
    if (result)
    {
        // build failed
        if (Yap.exists(fullExeTemp))
            Yap.remove(fullExeTemp);

        return result;
    }
    // clean up the dir containing the object file, just not in dry
    // run mode because we haven't created any!
    if (!dryRun)
    {
        if (Yap.exists(objDir) && objDir.startsWith(workDir))
        {
            // We swallow the exception because of a potential race: two
            // concurrently-running scripts may attempt to remove this
            // directory. One will fail.
            collectException(Yap.rmdirRecurse(objDir));
        }
        Yap.rename(fullExeTemp, fullExe);
    }
    return 0;
}

// Run a program optionally writing the command line first
// If "replace" is true and the OS supports it, replace the current process.

private int run(string[] args, string output = null, bool replace = false)
{
    import std.conv;
    yap(replace ? "exec " : "spawn ", args.text);
    if (dryRun) return 0;

    if (replace && !output.ptr)
    {
        version (Windows)
            { /* Windows doesn't have exec, fall back to spawnProcess+wait */ }
        else
        {
            import std.process : execv;
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

// Given module rootModule, returns a mapping of all dependees .d
// source filenames to their corresponding .o files sitting in
// directory workDir. The mapping is obtained by running dmd -v against
// rootModule.

private string[string] getDependencies(string rootModule, string workDir,
        string objDir, string[] compilerFlags)
{
    immutable depsFilename = buildPath(workDir, "rdmd.deps");

    string[string] readDepsFile()
    {
        string d2obj(string dfile)
        {
            return buildPath(objDir, dfile.baseName.chomp(".d") ~ objExt);
        }
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
                    if (Yap.exists(path))
                        return absolutePath(path);
                }
            return null;
        }
        yap("read ", depsFilename);
        auto depsReader = File(depsFilename);
        scope(exit) collectException(depsReader.close()); // don't care for errors

        // Fetch all dependencies and append them to myDeps
        auto pattern = ctRegex!(r"^(import|file|binary|config|library)\s+([^\(]+)\(?([^\)]*)\)?\s*$");
        string[string] result;
        foreach (string line; lines(depsReader))
        {
            auto regexMatch = match(line, pattern);
            if (regexMatch.empty) continue;
            auto captures = regexMatch.captures;
            switch(captures[1])
            {
            case "import":
                immutable moduleName = captures[2].strip(), moduleSrc = captures[3].strip();
                if (inALibrary(moduleName, moduleSrc)) continue;
                immutable moduleObj = d2obj(moduleSrc);
                result[moduleSrc] = moduleObj;
                break;

            case "file":
                result[captures[3].strip()] = null;
                break;

            case "binary":
                result[which(captures[2].strip())] = null;
                break;

            case "config":
                auto confFile = captures[2].strip;
                // The config file is special: if missing, that's fine too. So
                // add it as a dependency only if it actually exists.
                if (Yap.exists(confFile))
                {
                    result[confFile] = null;
                }
                break;

            case "library":
                immutable libName = captures[2].strip();
                immutable libPath = findLib(libName);
                if (libPath.ptr)
                {
                    yap("library ", libName, " ", libPath);
                    result[libPath] = null;
                }
                break;

            default: assert(0);
            }
        }
        // All dependencies specified through --extra-file
        foreach (immutable moduleSrc; extraFiles)
            result[moduleSrc] = d2obj(moduleSrc);
        return result;
    }

    // Check if the old dependency file is fine
    if (!force)
    {
        auto depsT = Yap.timeLastModified(depsFilename, SysTime.min);
        if (depsT > SysTime.min)
        {
            // See if the deps file is still in good shape
            auto deps = readDepsFile();
            auto allDeps = chain(rootModule.only, deps.byKey);
            bool mustRebuildDeps = allDeps.anyNewerThan(depsT);
            if (!mustRebuildDeps)
            {
                // Cool, we're in good shape
                return deps;
            }
            // Fall through to rebuilding the deps file
        }
    }

    immutable rootDir = dirName(rootModule);

    // Filter out -lib. With -o-, it will create an empty library file.
    compilerFlags = compilerFlags.filter!(flag => flag != "-lib").array();

    // Collect dependencies
    auto depsGetter =
        // "cd " ~ shellQuote(rootDir) ~ " && "
        [ compiler ] ~ compilerFlags ~
        ["-v", "-o-", rootModule, "-I" ~ rootDir];

    scope(failure)
    {
        // Delete the deps file on failure, we don't want to be fooled
        // by it next time we try
        collectException(std.file.remove(depsFilename));
    }

    immutable depsExitCode = run(depsGetter, depsFilename);
    if (depsExitCode)
    {
        stderr.writefln("Failed: %s", depsGetter);
        collectException(std.file.remove(depsFilename));
        exit(depsExitCode);
    }

    return dryRun ? null : readDepsFile();
}

// Is any file newer than the given file?
bool anyNewerThan(T)(T files, in string file)
{
    return files.anyNewerThan(Yap.timeLastModified(file));
}

// Is any file newer than the given file?
bool anyNewerThan(T)(T files, SysTime t)
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

/*
If force is true, returns true. Otherwise, if source and target both
exist, returns true iff source's timeLastModified is strictly greater
than target's. Otherwise, returns true.
 */
private bool newerThan(string source, string target)
{
    if (force) return true;
    return source.newerThan(Yap.timeLastModified(target, SysTime.min));
}

private bool newerThan(string source, SysTime target)
{
    if (force) return true;
    try
    {
        return Yap.timeLastModified(DirEntry(source)) > target;
    }
    catch (Exception)
    {
        // File not there, consider it newer
        return true;
    }
}

private @property string helpString()
{
    return
"rdmd build " ~ thisVersion ~ "
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
  --include=package  negate --exclude or a standard package (%-(%s, %))
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
  --tmpdir           set an alternative temporary directory
".format(defaultCompiler, defaultExclusions);
}

// For --eval and --loop
immutable string importWorld = "
module temporary;
import std.stdio, std.algorithm, std.array, std.ascii, std.base64,
    std.bigint, std.bitmanip,
    std.compiler, std.complex, std.concurrency, std.container, std.conv,
    std.csv,
    std.datetime, std.demangle, std.digest.md, std.encoding, std.exception,
    std.file,
    std.format, std.functional, std.getopt, std.json,
    std.math, std.mathspecial, std.mmfile,
    std.numeric, std.outbuffer, std.parallelism, std.path, std.process,
    std.random, std.range, std.regex, std.signals, std.socket,
    std.stdint, std.stdio,
    std.string, std.windows.syserror, std.system, std.traits, std.typecons,
    std.typetuple, std.uni, std.uri, std.utf, std.variant, std.xml, std.zip,
    std.zlib;
";

/**
Joins together the code provided via an `--eval` or `--loop`
flag, ensuring a trailing `;` is added if not already provided
by the user

Params:
    eval = array of strings generated by the `--eval`
           or `--loop` rdmd flags

Returns:
    string of code to be evaluated, corresponding to the
    inner code of either the program or the loop
*/
string innerEvalCode(string[] eval)
{
    import std.string : join, stripRight;
    // assumeSafeAppend just to avoid unnecessary reallocation
    string code = eval.join("\n").stripRight.assumeSafeAppend;
    if (code.length > 0 && code[$ - 1] != ';')
        code ~= ';';
    return code;
}

unittest
{
    assert(innerEvalCode([`writeln("Hello!")`]) == `writeln("Hello!");`);
    assert(innerEvalCode([`writeln("Hello!");`]) == `writeln("Hello!");`);

    // test with trailing whitespace
    assert(innerEvalCode([`writeln("Hello!")  `]) == `writeln("Hello!");`);
    assert(innerEvalCode([`writeln("Hello!");  `]) == `writeln("Hello!");`);

    // test with multiple entries
    assert(innerEvalCode([`writeln("Hello!");  `, `writeln("You!")  `])
           == "writeln(\"Hello!\");  \nwriteln(\"You!\");");
    assert(innerEvalCode([`writeln("Hello!");  `, `writeln("You!"); `])
           == "writeln(\"Hello!\");  \nwriteln(\"You!\");");
}

/**
Formats the code provided via `--eval` or `--loop` flags into a
string of complete program code that can be written to a file
and then compiled

Params:
    eval = array of strings generated by the `--eval` or
           `--loop` rdmd flags
    loop = set to `Yes.loop` if this code comes from a
           `--loop` flag, `No.loop` if it comes from an
           `--eval` flag

Returns:
    string of code to be evaluated, corresponding to the
    inner code of either the program or the loop
*/
string makeEvalCode(string[] eval, Flag!"loop" loop)
{
    import std.format : format;
    immutable codeFormat = importWorld
        ~ "void main(char[][] args) {%s%s\n%s}";

    immutable innerCodeOpening =
        loop ? " foreach (line; std.stdio.stdin.byLine()) {\n"
             : "\n";

    immutable innerCodeClosing = loop ? "} " : "";

    return format(codeFormat,
                  innerCodeOpening,
                  innerEvalCode(eval),
                  innerCodeClosing);
}

unittest
{
    // innerEvalCode already tests the cases for different
    // contents in `eval` array, so let's focus on testing
    // the difference based on the `loop` flag
    assert(makeEvalCode([`writeln("Hello!") `], No.loop) ==
           importWorld
           ~ "void main(char[][] args) {\n"
           ~ "writeln(\"Hello!\");\n}");

    assert(makeEvalCode([`writeln("What!"); `], No.loop) ==
           importWorld
           ~ "void main(char[][] args) {\n"
           ~ "writeln(\"What!\");\n}");

    assert(makeEvalCode([`writeln("Loop!") ; `], Yes.loop) ==
           importWorld
           ~ "void main(char[][] args) { "
           ~ "foreach (line; std.stdio.stdin.byLine()) {\n"
           ~ "writeln(\"Loop!\") ;\n} }");
}

string makeEvalFile(string todo)
{
    auto pathname = myOwnTmpDir;
    auto srcfile = buildPath(pathname,
            "eval." ~ todo.md5Of.toHexString ~ ".d");

    if (force || !Yap.exists(srcfile))
    {
        std.file.write(srcfile, todo);
    }

    // Clean pathname
    enum lifetimeInHours = 24;
    auto cutoff = Clock.currTime() - dur!"hours"(lifetimeInHours);
    yap("dirEntries ", pathname);
    foreach (DirEntry d; dirEntries(pathname, SpanMode.shallow))
    {
        if (Yap.timeLastModified(d) < cutoff)
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
        day = d[4] == ' ' ? "0" ~ d[5] : d[4 .. 6],
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
    static assert(month != "", "Unknown month " ~ month);
    return year[0] ~ year[1 .. $] ~ monthNum ~ day;
}

string which(string path)
{
    yap("which ", path);
    if (path.canFind(dirSeparator) || altDirSeparator != "" && path.canFind(altDirSeparator)) return path;
    string[] extensions = [""];
    version(Windows) extensions ~= environment["PATHEXT"].split(pathSeparator);
    foreach (envPath; environment["PATH"].splitter(pathSeparator))
    {
        foreach (extension; extensions)
        {
            string absPath = buildPath(envPath, path ~ extension);
            if (Yap.existsAsFile(absPath))
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

struct FileAttributes
{
    uint attributes;
    bool exists() const { return attributes != 0xFFFFFFFF; }
    bool isFile() const
        in { assert(exists); } do
    {
        import std.file : attrIsFile;
        return attrIsFile(attributes);
    }
}

struct Yap
{
    static FileAttributes getFileAttributes(const(char)[] name)
    {
        yap("stat ", name);
        import std.internal.cstring : tempCString;
        version(Windows)
        {
            import core.sys.windows.windows : GetFileAttributesW;
            auto attributes = GetFileAttributesW(name.tempCString!wchar());
            return FileAttributes(attributes);
        }
        else version(Posix)
        {
            import core.sys.posix.sys.stat : stat_t, stat;
            stat_t statbuf = void;
            return FileAttributes(
                (0 == stat(name.tempCString(), &statbuf)) ? statbuf.st_mode : 0xFFFFFFFF);
        }
        else static assert(0);
    }
    static bool exists(const(char)[] name)
    {
        return Yap.getFileAttributes(name).exists();
    }
    static bool existsAsFile(const(char)[] name)
    {
        auto attributes = Yap.getFileAttributes(name);
        return attributes.exists() && attributes.isFile();
    }
    static auto timeLastModified(R)(R name)
    {
        yap("stat ", name);
        return std.file.timeLastModified(name);
    }
    static auto timeLastModified(R)(R name, SysTime returnIfMissing)
    {
        yap("stat ", name);
        return std.file.timeLastModified(name, returnIfMissing);
    }
    static void rename(R,S)(R from, S to)
    {
        yap("mv ", from, " ", to);
        std.file.rename(from, to);
    }
    static void remove(R)(R name)
    {
        yap("rm ", name);
        std.file.remove(name);
    }
    static void mkdirRecurseIfLive(const(char)[] name)
    {
        yap("mkdirRecurse ", name);
        if (!dryRun)
            std.file.mkdirRecurse(name);
    }
    static void rmdirRecurse(const(char)[] name)
    {
        yap("rmdirRecurse ", name);
        std.file.rmdirRecurse(name);
    }
}
