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

import std.algorithm, std.array, std.c.stdlib, std.datetime,
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
    import std.c.windows.windows;
    extern(Windows) HINSTANCE ShellExecuteA(HWND, LPCSTR, LPCSTR, LPCSTR, LPCSTR, INT);
    enum objExt = ".obj";
    enum binExt = ".exe";
    enum libExt = ".lib";
    enum altDirSeparator = "/";
}
else
{
    static assert(0, "Unsupported operating system.");
}

private bool chatty, buildOnly, dryRun, force;
private string exe;
private string[] exclusions = ["std", "core", "tango"]; // packages that are to be excluded

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
            if (!exe) // Don't let -od override -of
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
        else if (value[0] == 'p') { }  // -op
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
            "force", &force,
            "help", { writeln(helpString); bailout = true; },
            "main", &addStubMain,
            "makedepend", &makeDepend,
            "man", { man(); bailout = true; },
            "o", &dashOh);
    if (bailout) return 0;
    if (dryRun) chatty = true; // dry-run implies chatty

    // Just evaluate this program!
    if (loop)
    {
        return .eval(importWorld ~ "void main(char[][] args) { "
                ~ "foreach (line; std.stdio.stdin.byLine()) {\n"
                ~ std.string.join(loop, "\n")
                ~ ";\n} }");
    }
    if (eval)
    {
        return .eval(importWorld ~ "void main(char[][] args) {\n"
                ~ std.string.join(eval, "\n") ~ ";\n}");
    }

    // no code on command line => require a source file
    if (programPos == args.length)
    {
        write(helpString);
        return 1;
    }

    auto
        root = args[programPos].chomp(".d") ~ ".d",
        exeBasename = root.baseName(".d"),
        exeDirname = root.dirName,
        programArgs = args[programPos + 1 .. $];

    assert(argsBeforeProgram.length >= 1);
    auto compilerFlags = argsBeforeProgram[1 .. $];

    bool lib = compilerFlags.canFind("-lib");
    string outExt = lib ? libExt : binExt;

    // --build-only implies the user would like a binary in the program's directory
    if (buildOnly && !exe)
        exe = exeDirname ~ dirSeparator;

    if (exe && exe.endsWith(dirSeparator))
    {
        // user specified a directory, complete it to a file
        exe = buildPath(exe, exeBasename) ~ outExt;
    }

    // Compute the object directory and ensure it exists
    immutable workDir = getWorkPath(root, compilerFlags);
    string objDir = buildPath(workDir, "objs");
    yap("stat ", workDir);
    if (exists(workDir))
    {
        enforce(dryRun || isDir(workDir),
                "Entry `"~workDir~"' exists but is not a directory.");
    }
    else
    {
        yap("mkdirRecurse ", workDir);
        mkdirRecurse(workDir);
    }

    if (exists(objDir))
    {
        enforce(dryRun || isDir(objDir),
                "Entry `"~objDir~"' exists but is not a directory.");
    }
    else
    {
        yap("mkdirRecurse ", objDir);
        mkdirRecurse(objDir);
    }

    if (lib)
    {
        // When building libraries, DMD does not generate object files.
        // Instead, it uses the -od parameter as the location for the library file.
        // Thus, override objDir (which is normally a temporary directory)
        // to be the target output directory.
        objDir = exe.dirName;
    }

    // Fetch dependencies
    const myDeps = getDependencies(root, workDir, objDir, compilerFlags);

    // --makedepend mode. Just print dependencies and exit.
    if (makeDepend)
    {
        stdout.write(root, " :");
        foreach (mod, _; myDeps)
        {
            stdout.write(' ', mod);
        }
        stdout.writeln();
        return 0;
    }

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
    if (exe)
    {
        // user-specified exe name
        buildWitness = buildPath(workDir, ".built");
        if (!exe.newerThan(buildWitness))
        {
            // Both exe and buildWitness exist, and exe is older than
            // buildWitness. This is the only situation in which we
            // may NOT need to recompile.
            lastBuildTime = buildWitness.timeLastModified(SysTime.min);
        }
    }
    else
    {
        exe = buildPath(workDir, exeBasename) ~ outExt;
        buildWitness = exe;
        lastBuildTime = buildWitness.timeLastModified(SysTime.min);
    }

    // Have at it
    if (chain(root.only, myDeps.byKey).array.anyNewerThan(lastBuildTime))
    {
        immutable result = rebuild(root, exe, workDir, objDir,
                                   myDeps, compilerFlags, addStubMain);
        if (result)
        {
            if (exists(exe))
                remove(exe);
            return result;
        }

        // Touch the build witness to track the build time
        if (buildWitness != exe)
        {
            yap("touch ", buildWitness);
            std.file.write(buildWitness, "");
        }
    }

    if (buildOnly)
    {
        // Pretty much done!
        return 0;
    }

    // run
    return exec([ exe ] ~ programArgs);
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

bool inALibrary(string source, string object)
{
    if (object.endsWith(".di")
            || source == "object" || source == "gcstats")
        return true;

    foreach(string exclusion; exclusions)
        if (source.startsWith(exclusion~'.'))
            return true;

    return false;

    // another crude heuristic: if a module's path is absolute, it's
    // considered to be compiled in a separate library. Otherwise,
    // it's a source module.
    //return isabs(mod);
}

private @property string myOwnTmpDir()
{
    version (Posix)
    {
        import core.sys.posix.unistd;
        auto tmpRoot = format("/tmp/.rdmd-%d", getuid());
    }
    else version (Windows)
    {
        auto tmpRoot = std.process.getenv("TEMP");
        if (!tmpRoot)
        {
            tmpRoot = std.process.getenv("TMP");
        }
        if (!tmpRoot) tmpRoot = buildPath(".", ".rdmd");
        else tmpRoot = tmpRoot.replace("/", dirSeparator) ~ dirSeparator ~ ".rdmd";
    }
    yap("stat ", tmpRoot);
    if (exists(tmpRoot))
    {
        enforce(isDir(tmpRoot),
                "Entry `"~tmpRoot~"' exists but is not a directory.");
    }
    else
    {
        mkdirRecurse(tmpRoot);
    }
    return tmpRoot;
}

private string getWorkPath(in string root, in string[] compilerFlags)
{
    enum string[] irrelevantSwitches = [
        "--help", "-ignore", "-quiet", "-v" ];

    MD5 context;
    context.start();
    context.put(getcwd().representation);
    context.put(root.representation);
    foreach (flag; compilerFlags)
    {
        if (irrelevantSwitches.canFind(flag)) continue;
        context.put(flag.representation);
    }
    auto digest = context.finish();
    string hash = toHexString(digest);

    const tmpRoot = myOwnTmpDir;
    return buildPath(tmpRoot,
            "rdmd-" ~ baseName(root) ~ '-' ~ hash);
}

// Rebuild the executable fullExe starting from modules in myDeps
// passing the compiler flags compilerFlags. Generates one large
// object file.

private int rebuild(string root, string fullExe,
        string workDir, string objDir, in string[string] myDeps,
        string[] compilerFlags, bool addStubMain)
{
    string[] buildTodo()
    {
        auto todo = compilerFlags
            ~ [ "-of"~fullExe ]
            ~ [ "-od"~objDir ]
            ~ [ "-I"~dirName(root) ]
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

        todo = [ "@"~rspName ];
    }

    immutable result = run([ compiler ] ~ todo);
    if (result)
    {
        // build failed
        return result;
    }
    // clean up the dir containing the object file, just not in dry
    // run mode because we haven't created any!
    if (!dryRun)
    {
        yap("stat ", objDir);
        if (objDir.exists && objDir.startsWith(workDir))
        {
            yap("rmdirRecurse ", objDir);
            // We swallow the exception because of a potential race: two
            // concurrently-running scripts may attempt to remove this
            // directory. One will fail.
            collectException(rmdirRecurse(objDir));
        }
    }
    return 0;
}

// Run a program optionally writing the command line first

private int run(string[] argv, string output = null, bool shell = true)
{
    string command = escapeShellCommand(argv);
    yap(command);
    if (dryRun) return 0;

    if (output)
    {
        shell = true;
        command ~= " > " ~ escapeShellFileName(output);
    }

    version (Windows)
    {
        shell = true;
        // Follow CMD's rules for quote parsing (see "cmd /?").
        command = '"' ~ command ~ '"';
    }

    if (shell)
    {
        return system(command);
    }
    return execv(argv[0], argv);
}

private int exec(string[] argv)
{
    return run(argv, null, false);
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
                    if (path.exists)
                        return absolutePath(path);
                }
            return null;
        }
        yap("read ", depsFilename);
        auto depsReader = File(depsFilename);
        scope(exit) collectException(depsReader.close()); // don't care for errors

        // Fetch all dependencies and append them to myDeps
        auto pattern = regex(r"^(import|file|binary|config|library)\s+([^\(]+)\(?([^\)]*)\)?\s*$");
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
                result[captures[2].strip()] = null;
                break;

            case "library":
                immutable libName = captures[2].strip();
                immutable libPath = findLib(libName);
                if (libPath)
                {
                    yap("library ", libName, " ", libPath);
                    result[libPath] = null;
                }
                break;

            default: assert(0);
            }
        }
        return result;
    }

    // Check if the old dependency file is fine
    if (!force)
    {
        yap("stat ", depsFilename);
        if (exists(depsFilename))
        {
            // See if the deps file is still in good shape
            auto deps = readDepsFile();
            auto allDeps = chain(rootModule.only, deps.byKey).array;
            bool mustRebuildDeps = allDeps.anyNewerThan(timeLastModified(depsFilename));
            if (!mustRebuildDeps)
            {
                // Cool, we're in good shape
                return deps;
            }
            // Fall through to rebuilding the deps file
        }
    }

    immutable rootDir = dirName(rootModule);

    // Collect dependencies
    auto depsGetter =
        // "cd "~shellQuote(rootDir)~" && "
        [ compiler ] ~ compilerFlags ~
        ["-v", "-o-", rootModule, "-I"~rootDir];

    scope(failure)
    {
        // Delete the deps file on failure, we don't want to be fooled
        // by it next time we try
        collectException(std.file.remove(depsFilename));
    }

    immutable depsExitCode = run(depsGetter, depsFilename);
    if (depsExitCode)
    {
        stderr.writeln("Failed: ", escapeShellCommand(depsGetter));
        collectException(std.file.remove(depsFilename));
        exit(depsExitCode);
    }

    return dryRun ? null : readDepsFile();
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
    return source.newerThan(timeLastModified(target, SysTime(0)));
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

private @property string helpString()
{
    return
"rdmd build "~thisVersion~"
Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]...
Builds (with dependents) and runs a D program.
Example: rdmd -release myprog --myprogparm 5

Any option to be passed to the compiler must occur before the program name. In
addition to compiler options, rdmd recognizes the following options:
  --build-only      just build the executable, don't run it
  --chatty          write compiler commands to stdout before executing them
  --compiler=comp   use the specified compiler (e.g. gdmd) instead of %s
  --dry-run         do not compile, just show what commands would be run
                      (implies --chatty)
  --eval=code       evaluate code as in perl -e (multiple --eval allowed)
  --exclude=package exclude a package from the build (multiple --exclude allowed)
  --force           force a rebuild even if apparently not necessary
  --help            this message
  --loop            assume \"foreach (line; stdin.byLine()) { ... }\" for eval
  --main            add a stub main program to the mix (e.g. for unittesting)
  --makedepend      print dependencies in makefile format and exit
  --man             open web browser on manual page
  --shebang         rdmd is in a shebang line (put as first argument)
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
    std.math, std.mathspecial, std.metastrings, std.mmfile,
    std.numeric, std.outbuffer, std.parallelism, std.path, std.process,
    std.random, std.range, std.regex, std.signals, std.socket,
    std.socketstream, std.stdint, std.stdio, std.stdiobase, std.stream,
    std.string, std.syserror, std.system, std.traits, std.typecons,
    std.typetuple, std.uni, std.uri, std.utf, std.variant, std.xml, std.zip,
    std.zlib;
";

int eval(string todo)
{
    auto pathname = myOwnTmpDir;
    auto progname = buildPath(pathname,
            "eval." ~ todo.md5Of.toHexString);
    auto binName = progname ~ binExt;

    bool compileFailure = false;
    if (force || !exists(binName))
    {
        // Compile it
        std.file.write(progname~".d", todo);
        if( run([ compiler, progname ~ ".d", "-of" ~ binName ]) != 0 )
            compileFailure = true;
    }

    if (!compileFailure)
    {
        // Run it
        exec([ binName ]);
    }

    // Clean pathname
    enum lifetimeInHours = 24;
    auto cutoff = Clock.currTime() - dur!"hours"(lifetimeInHours);
    yap("dirEntries ", pathname);
    foreach (DirEntry d; dirEntries(pathname, SpanMode.shallow))
    {
        if (d.timeLastModified < cutoff)
        {
            std.file.remove(d.name);
            //break; // only one per call so we don't waste time
        }
    }

    return 0;
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

