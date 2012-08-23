// Written in the D programming language.

import std.algorithm, std.array, std.c.stdlib, std.datetime,
    std.exception, std.file, std.getopt,
    std.md5, std.parallelism, std.path, std.process, std.regex,
    std.stdio, std.string, std.typetuple;

version (Posix)
{
    enum objExt = ".o";
    enum binExt = "";
    enum altDirSeparator = "";
}
else version (Windows)
{
    import std.c.windows.windows;
    extern(Windows) HINSTANCE ShellExecuteA(HWND, LPCSTR, LPCSTR, LPCSTR, LPCSTR, INT);
    enum objExt = ".obj";
    enum binExt = ".exe";
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
    //writeln("Invoked with: ", map!(q{a ~ ", "})(args));
    if (args.length > 1 && std.algorithm.startsWith(args[1],
                    "--shebang ", "--shebang="))
    {
        // multiple options wrapped in one
        auto a = args[1]["--shebang ".length .. $];
        args = args[0 .. 1] ~ std.string.split(a) ~ args[2 .. $];
    }

    // Continue parsing the command line; now get rdmd's own arguments
    // parse the -o option
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
            if(!exe) // Don't let -od override -of
            {
                // add a trailing dir separator to clarify it's a dir
                exe = value[1 .. $];
                if (!std.algorithm.endsWith(exe, dirSeparator))
                {
                    exe ~= dirSeparator;
                }
                assert(std.algorithm.endsWith(exe, dirSeparator));
            }
        }
        else if (value[0] == '-')
        {
            // -o- passed
            enforce(false, "Option -o- currently not supported by rdmd");
        }
        else
        {
            enforce(false, "Unrecognized option: "~key~value);
        }
    }

    // start the web browser on documentation page
    void man()
    {
        version(Windows)
        {
            // invoke browser that is associated with the http protocol
            ShellExecuteA(null, "open", "http://www.digitalmars.com/d/2.0/rdmd.html", null, null, SW_SHOWNORMAL);
        }
        else
        {
            foreach (b; [ std.process.getenv("BROWSER"), "firefox",
                            "sensible-browser", "x-www-browser" ]) {
                if (!b.length) continue;

                if (!system(b~" http://www.digitalmars.com/d/2.0/rdmd.html"))
                    return;
            }
        }
    }

    auto programPos = indexOfProgram(args);
    // Insert "--" to tell getopts when to stop
    args = args[0..programPos] ~ "--" ~ args[programPos .. $];

    bool bailout;    // bailout set by functions called in getopt if
                     // program should exit
    string[] loop;       // set by --loop
    bool addStubMain;// set by --main
    string[] eval;     // set by --eval
    bool makeDepend;
    getopt(args,
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
                ~ "foreach (line; stdin.byLine()) {\n"
                ~ std.string.join(loop, "\n")
                ~ ";\n} }");
    }
    if (eval)
    {
        return .eval(importWorld ~ "void main(char[][] args) {\n"
                ~ std.string.join(eval, "\n") ~ ";\n}");
    }

    // Parse the program line - first find the program to run
    programPos = indexOfProgram(args);
    if (programPos == args.length)
    {
        write(helpString);
        return 1;
    }
    auto
        root = /*absolutePath*/(chomp(args[programPos], ".d") ~ ".d"),
        exeBasename = baseName(root, ".d"),
        exeDirname = dirName(root),
        programArgs = args[programPos + 1 .. $];
    args = args[0 .. programPos];
    auto compilerFlags = args[1 .. programPos - 1];

    // --build-only implies the user would like a binary in the program's directory
    if (buildOnly && !exe)
        exe = exeDirname ~ dirSeparator;

    // Compute the object directory and ensure it exists
    immutable workDir = getWorkPath(root, compilerFlags);
    immutable objDir = buildPath(workDir, "objs");
    exists(workDir)
        ? enforce(dryRun || isDir(workDir),
                "Entry `"~workDir~"' exists but is not a directory.")
        : mkdir(workDir);

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
    if (exe)
    {
        // user-specified exe name
        if (std.algorithm.endsWith(exe, dirSeparator))
        {
            // user specified a directory, complete it to a file
            exe = buildPath(exe, exeBasename) ~ binExt;
        }
    }
    else
    {
        exe = buildPath(workDir, exeBasename) ~ binExt;
    }

    // Have at it
    if (isNewer(root, exe) || anyNewerThan(myDeps.keys, exe))
    {
        immutable result = rebuild(root, exe, workDir, objDir,
                                   myDeps, compilerFlags, addStubMain);
        if (result)
        {
            if (exists(exe))
                remove(exe);
            return result;
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
    foreach(i, arg; args)
    {
        if (i > 0 &&
                !arg.startsWith('-', '@') &&
                !arg.endsWith(".obj", ".o", ".lib", ".a", ".def", ".map"))
        {
            return i;
        }
    }

    return args.length;
}

bool inALibrary(string source, string object)
{
    if (std.string.endsWith(object, ".di")
        || source == "object" || source == "gcstats")
        return true;

    foreach(string exclusion; exclusions)
        if (std.string.startsWith(source, exclusion~'.'))
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
        else tmpRoot ~= dirSeparator ~ ".rdmd";
    }
    exists(tmpRoot) && isDir(tmpRoot) || mkdirRecurse(tmpRoot);
    return tmpRoot;
}

private string getWorkPath(in string root, in string[] compilerFlags)
{
    enum string[] irrelevantSwitches = [
        "--help", "-ignore", "-quiet", "-v" ];
    MD5_CTX context;
    context.start();
    context.update(getcwd());
    context.update(root);
    foreach (flag; compilerFlags) {
        if (find(irrelevantSwitches, flag).length) continue;
        context.update(flag);
    }
    ubyte digest[16];
    context.finish(digest);
    string hash = digestToString(digest);

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
    if (!dryRun && exists(objDir)) {
        rmdirRecurse(objDir);
    }
    return 0;
}

// Run a program optionally writing the command line first

private int run(string[] argv, string output = null, bool shell = true)
{
    string command = escapeShellCommand(argv);
    if (chatty) writeln(command);
    if (dryRun) return 0;

    if (output)
    {
        shell = true;
        command ~= " > " ~ escapeShellArgument(output);
    }

    version (Windows)
    {
        shell = true;

        // Follow CMD's rules for quote parsing (see "cmd /?").
        command = '"' ~ command ~ '"';
    }

    if (shell)
        return system(command);
    else
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
            return buildPath(objDir, chomp(baseName(dfile), ".d")~objExt);
        }
        auto depsReader = File(depsFilename);
        scope(exit) collectException(depsReader.close()); // don't care for errors

        // Fetch all dependencies and append them to myDeps
        auto pattern = regex(r"^(import|file|binary|config)\s+([^\(]+)\(?([^\)]*)\)?\s*$");
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

            default: assert(0);
            }
        }
        return result;
    }

    // Check if the old dependency file is fine
    if (!force && std.file.exists(depsFilename))
    {
        // See if the deps file is still in good shape
        auto deps = readDepsFile();
        bool mustRebuildDeps = anyNewerThan(deps.keys, depsFilename);
        if (!mustRebuildDeps)
        {
            // Cool, we're in good shape
            return deps;
        }
        // Fall through to rebuilding the deps file
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

    return readDepsFile();
}

// Is any file newer than the given file?
bool anyNewerThan(in string[] files, in string file)
{
    // Experimental: running isNewer in separate threads, one per file
    if (false)
    {
        foreach (source; files)
        {
            if (isNewer(source, file))
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
            if (!result && isNewer(source, file))
            {
                result = true;
            }
        }
        return result;
    }
}

// Quote an argument in a manner conforming to the behavior of
// CommandLineToArgvW and DMD's response-file parsing algorithm.
// References:
// * http://msdn.microsoft.com/en-us/library/windows/desktop/bb776391.aspx
// * http://blogs.msdn.com/b/oldnewthing/archive/2010/09/17/10063629.aspx
// * https://github.com/D-Programming-Language/dmd/blob/master/src/root/response.c

/*private*/ string escapeWindowsArgument(string arg)
{
    // Escape trailing backslashes, so they don't escape the ending quote.
    // Backslashes elsewhere should NOT be escaped.
    for (ptrdiff_t i=arg.length-1; i>=0 && arg[i]=='\\'; i--)
        arg ~= '\\';
    return '"' ~ std.array.replace(arg, `"`, `\"`) ~ '"';
}

version(Windows) version(unittest)
{
    extern (Windows) wchar_t**  CommandLineToArgvW(wchar_t*, int*);
    extern (C) size_t wcslen(in wchar *);

    unittest
    {
        string[] testStrings = [
            ``, `\`, `"`, `""`, `"\`, `\"`, `\\`, `\\"`,
            `Hello`,
            `Hello, world`
            `Hello, "world"`,
            `C:\`,
            `C:\dmd`,
            `C:\Program Files\`,
        ];

        import std.conv;

        foreach (s; testStrings)
        {
            auto q = escapeWindowsArgument(s);
            LPWSTR lpCommandLine = (to!(wchar[])("Dummy.exe " ~ q) ~ "\0"w).ptr;
            int numArgs;
            LPWSTR* args = CommandLineToArgvW(lpCommandLine, &numArgs);
            scope(exit) LocalFree(args);
            assert(numArgs==2, s ~ " => " ~ q ~ " #" ~ text(numArgs-1));
            auto arg = to!string(args[1][0..wcslen(args[1])]);
            assert(arg == s, s ~ " => " ~ q ~ " => " ~ arg);
        }
    }
}

/*private*/ string escapeShellArgument(string arg)
{
    version (Windows)
    {
        return escapeWindowsArgument(arg);
    }
    else
    {
        // '\'' means: close quoted part of argument, append an escaped
        // single quote, and reopen quotes
        return `'` ~ std.array.replace(arg, `'`, `'\''`) ~ `'`;
    }
}

private string escapeShellCommand(string[] args)
{
    return array(map!escapeShellArgument(args)).join(" ");
}

private bool isNewer(string source, string target)
{
    return force || !source.exists() ||
        timeLastModified(source) >= timeLastModified(target, SysTime(0));
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
  --eval=code       evaluate code \u00E0 la perl -e (multiple --eval allowed)
  --exclude=package exclude a package from the build (multiple --exclude allowed)
  --force           force a rebuild even if apparently not necessary
  --help            this message
  --loop            assume \"foreach (line; stdin.byLine()) { ... }\" for eval
  --main            add a stub main program to the mix (e.g. for unittesting)
  --makedepend      print dependencies in makefile format and exit
  --man             open web browser on manual page
  --shebang         rdmd is in a shebang line (put as first argument)
".format(compiler);
}

// For --eval
immutable string importWorld = "
module temporary;
import std.stdio, std.algorithm, std.array, std.ascii, std.base64,
    std.bigint, std.bitmanip,
    std.compiler, std.complex, std.concurrency, std.container, std.conv,
    std.cpuid, std.cstream, std.csv,
    std.datetime, std.demangle, std.encoding, std.exception,
    std.file,
    std.format, std.functional, std.getopt, std.json,
    std.math, std.mathspecial, std.md5, std.metastrings, std.mmfile,
    std.numeric, std.outbuffer, std.parallelism, std.path, std.process,
    std.random, std.range, std.regex, std.signals, std.socket,
    std.socketstream, std.stdint, std.stdio, std.stdiobase, std.stream,
    std.string, std.syserror, std.system, std.traits, std.typecons,
    std.typetuple, std.uni, std.uri, std.utf, std.variant, std.xml, std.zip,
    std.zlib;
";

int eval(string todo)
{
    MD5_CTX context;
    context.start();
    context.update(todo);
    ubyte digest[16];
    context.finish(digest);
    auto pathname = myOwnTmpDir;
    auto progname = buildPath(pathname,
            "eval." ~ digestToString(digest));
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
    if (path.canFind(dirSeparator) || altDirSeparator != "" && path.canFind(altDirSeparator)) return path;
    foreach (envPath; std.algorithm.splitter(std.process.environment["PATH"], pathSeparator))
    {
        string absPath = buildPath(envPath, path);
        if (exists(absPath) && isFile(absPath)) return absPath;
    }
    throw new FileException(path, "File not found in PATH");
}

/*
 *  Copyright (C) 2008 by Andrei Alexandrescu
 *  Written by Andrei Alexandrescu, www.erdani.org
 *  Based on an idea by Georg Wrede
 *  Featuring improvements suggested by Christopher Wright
 *  Windows port using bug fixes and suggestions by Adam Ruppe
 *
 *  This software is provided 'as-is', without any express or implied
 *  warranty. In no event will the authors be held liable for any damages
 *  arising from the use of this software.
 *
 *  Permission is granted to anyone to use this software for any purpose,
 *  including commercial applications, and to alter it and redistribute it
 *  freely, subject to the following restrictions:
 *
 *  o  The origin of this software must not be misrepresented; you must not
 *     claim that you wrote the original software. If you use this software
 *     in a product, an acknowledgment in the product documentation would be
 *     appreciated but is not required.
 *  o  Altered source versions must be plainly marked as such, and must not
 *     be misrepresented as being the original software.
 *  o  This notice may not be removed or altered from any source
 *     distribution.
 */
