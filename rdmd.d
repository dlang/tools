// Written in the D programming language.

import std.algorithm, std.array, std.c.stdlib, std.datetime,
    std.exception, std.file, std.getopt,
    std.md5, std.path, std.process, std.regex,
    std.stdio, std.string, std.typetuple;

version (Posix)
{
    enum objExt = ".o";
    enum binExt = "";
}
else version (Windows)
{
    import std.c.windows.windows;
    extern(Windows) HINSTANCE ShellExecuteA(HWND, LPCSTR, LPCSTR, LPCSTR, LPCSTR, INT);
    enum objExt = ".obj";
    enum binExt = ".exe";
}
else
{
    static assert(0, "Unsupported operating system.");
}

private bool chatty, buildOnly, dryRun, force;
private string exe, compiler = "dmd";

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
                // add a trailing path separator to clarify it's a dir
                exe = value[1 .. $];
                if (!std.algorithm.endsWith(exe, std.path.sep[]))
                {
                    exe ~= std.path.sep[];
                }
                assert(std.algorithm.endsWith(exe, std.path.sep[]));
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
            "force", &force,
            "help", (string) { writeln(helpString); bailout = true; },
            "main", &addStubMain,
            "makedepend", &makeDepend,
            "man", (string) { man; bailout = true; },
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
        root = /*rel2abs*/(chomp(args[programPos], ".d") ~ ".d"),
        exeBasename = basename(root, ".d"),
        exeDirname = dirname(root),
        programArgs = args[programPos + 1 .. $];
    args = args[0 .. programPos];
    auto compilerFlags = args[1 .. programPos - 1];

    // --build-only implies the user would like a binary in the current directory
    if (buildOnly && !exe)
        exe = "." ~ std.path.sep;

    // Compute the object directory and ensure it exists
    immutable objDir = getObjPath(root, compilerFlags);
    // Fetch dependencies
    const myDeps = getDependencies(root, objDir, compilerFlags);

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

    if (!dryRun)        
    {
        exists(objDir)
            ? enforce(dryRun || isDir(objDir),
                    "Entry `"~objDir~"' exists but is not a directory.")
            : mkdir(objDir);
    }

    // Compute executable name, check for freshness, rebuild
    if (exe)
    {
        // user-specified exe name
        if (std.algorithm.endsWith(exe, std.path.sep[]))
        {
            // user specified a directory, complete it to a file
            exe = std.path.join(exe, exeBasename) ~ binExt;
        }
    }
    else
    {
        //exe = exeBasename ~ '.' ~ hash(root, compilerFlags);
        version (Posix)
            exe = std.path.join(myOwnTmpDir, rel2abs(root)[1 .. $])
                ~ '.' ~ hash(root, compilerFlags) ~ binExt;
        else version (Windows)
            exe = std.path.join(myOwnTmpDir, replace(root, ".", "-"))
                ~ '-' ~ hash(root, compilerFlags) ~ binExt;
        else
            static assert(0);
    }

    // Have at it
    if (isNewer(root, exe) ||
            std.algorithm.find!
                ((string a) {return isNewer(a, exe);})
                (myDeps.keys).length)
    {
        immutable result = rebuild(root, exe, objDir, myDeps, compilerFlags,
                                   addStubMain);
        if (result) return result;
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
    // Heuristics: if source starts with "std.", it's in a library
    return std.string.startsWith(source, "std.")
        || std.string.startsWith(source, "core.")
        || std.string.startsWith(source, "tango.")
        || std.string.endsWith(object, ".di")
        || source == "object" || source == "gcstats";
    // another crude heuristic: if a module's path is absolute, it's
    // considered to be compiled in a separate library. Otherwise,
    // it's a source module.
    //return isabs(mod);
}

private string myOwnTmpDir()
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
        if (!tmpRoot) tmpRoot = std.path.join(".", ".rdmd");
        else tmpRoot ~= sep ~ ".rdmd";
    }
    exists(tmpRoot) && isDir(tmpRoot) || mkdirRecurse(tmpRoot);
    return tmpRoot;
}

private string hash(in string root, in string[] compilerFlags)
{
    enum string[] irrelevantSwitches = [
        "--help", "-ignore", "-quiet", "-v" ];
    MD5_CTX context;
    context.start();
    context.update(getcwd);
    context.update(root);
    foreach (flag; compilerFlags) {
        if (find(irrelevantSwitches, flag).length) continue;
        context.update(flag);
    }
    ubyte digest[16];
    context.finish(digest);
    return digestToString(digest);
}

private string getObjPath(in string root, in string[] compilerFlags)
{
    const tmpRoot = myOwnTmpDir;
    return std.path.join(tmpRoot,
            "rdmd-" ~ basename(root) ~ '-' ~ hash(root, compilerFlags));
}

// Rebuild the executable fullExe starting from modules in myDeps
// passing the compiler flags compilerFlags. Generates one large
// object file.

private int rebuild(string root, string fullExe,
        string objDir, in string[string] myDeps,
        string[] compilerFlags, bool addStubMain)
{
    string[] buildTodo()
    {
        auto todo = compilerFlags
            ~ [ "-of"~fullExe ]
            ~ [ "-od"~objDir ]
            ~ [ "-I"~dirname(root) ]
            ~ [ root ];
        foreach (k, objectFile; myDeps) {
            if(objectFile !is null)
                todo ~= [ k ];
        }
        // Need to add void main(){}?
        if (addStubMain)
        {
            auto stubMain = std.path.join(myOwnTmpDir, "stubmain.d");
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
        auto rspName = std.path.join(myOwnTmpDir,
                "rdmd." ~ hash(root, compilerFlags) ~ ".rsp");

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
    if (!dryRun) {
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
// directory objDir. The mapping is obtained by running dmd -v against
// rootModule.

private string[string] getDependencies(string rootModule, string objDir,
        string[] compilerFlags)
{
    string d2obj(string dfile)
    {
        return std.path.join(objDir, chomp(basename(dfile), ".d")~objExt);
    }

    immutable depsFilename = rootModule~".deps";
    immutable rootDir = dirname(rootModule);

    // myDeps maps dependency paths to corresponding .o name (or null, if not a D module)
    string[string] myDeps;// = [ rootModule : d2obj(rootModule) ];
    // Must collect dependencies
    auto depsGetter =
        // "cd "~shellQuote(rootDir)~" && "
        [ compiler ] ~ compilerFlags ~
        ["-v", "-o-", rootModule, "-I"~rootDir];
    immutable depsExitCode = run(depsGetter, depsFilename);
    if (depsExitCode)
    {
        stderr.writeln("Failed: ", escapeShellCommand(depsGetter));
        exit(depsExitCode);
    }
    auto depsReader = File(depsFilename);
    // Leave the deps file in place in case of failure, maybe the user
    // wants to take a look at it
    scope(success) collectException(std.file.remove(depsFilename));
    scope(exit) collectException(depsReader.close); // don't care for errors

    // Fetch all dependencies and append them to myDeps
    auto pattern = regex(r"^(import|file|binary|config)\s+([^\(]+)\(?([^\)]*)\)?\s*$");
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
            myDeps[moduleSrc] = moduleObj;
            break;
            
        case "file":
            myDeps[captures[3].strip()] = null;
            break;
            
        case "binary":
            myDeps[which(captures[2].strip())] = null;
            break;
        
        case "config":
            myDeps[captures[2].strip()] = null;
            break;
            
        default: assert(0);
        }
    }

    return myDeps;
}

// Quote an argument in a manner conforming to the behavior of
// CommandLineToArgvW and DMD's response-file parsing algorithm.
// References:
// * http://msdn.microsoft.com/en-us/library/windows/desktop/bb776391(v=vs.85).aspx
// * http://blogs.msdn.com/b/oldnewthing/archive/2010/09/17/10063629.aspx
// * https://github.com/D-Programming-Language/dmd/blob/master/src/root/response.c

/*private*/ string escapeWindowsArgument(string arg)
{
    // Escape trailing backslashes, so they don't escape the ending quote.
    // Backslashes elsewhere should NOT be escaped.
    for (int i=arg.length-1; i>=0 && arg[i]=='\\'; i--)
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
    return force ||
        timeLastModified(source) >= timeLastModified(target, SysTime(0));
}

private string helpString()
{
    return
"rdmd build "~thisVersion~"
Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]...
Builds (with dependents) and runs a D program.
Example: rdmd -release myprog --myprogparm 5

Any option to be passed to dmd must occur before the program name. In addition
to dmd options, rdmd recognizes the following options:
  --build-only      just build the executable, don't run it
  --chatty          write dmd commands to stdout before executing them
  --compiler=comp   use the specified compiler (e.g. gdmd) instead of dmd
  --dry-run         do not compile, just show what commands would be run
                      (implies --chatty)
  --eval=code       evaluate code \u00E0 la perl -e (multiple --eval allowed)
  --force           force a rebuild even if apparently not necessary
  --help            this message
  --loop            assume \"foreach (line; stdin.byLine()) { ... }\" for eval
  --main            add a stub main program to the mix (e.g. for unittesting)
  --makedepend      print dependencies in makefile format and exit
  --man             open web browser on manual page
  --shebang         rdmd is in a shebang line (put as first argument)
";
}

// For --eval
immutable string importWorld = "
module temporary;
import std.stdio, std.algorithm, std.array, std.base64,
    std.bigint, std.bitmanip, 
    std.compiler, std.complex, std.conv, std.cpuid, std.cstream,
    std.ctype, std.datetime, std.demangle, std.encoding, std.exception, 
    std.file, 
    std.format, std.functional, std.getopt, 
    std.math, std.md5, std.metastrings, std.mmfile,
    std.numeric, std.outbuffer, std.path, std.process, 
    std.random, std.range, std.regex, std.regexp, std.signals, std.socket,
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
    auto progname = std.path.join(pathname,
            "eval." ~ digestToString(digest));
    auto binName = progname ~ binExt;

    if (exists(binName) ||
            // Compile it
            (std.file.write(progname~".d", todo),
                    run([ compiler, progname ~ ".d", "-of" ~ binName ]) == 0))
    {
        // It's there, just run it
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

string thisVersion()
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
    if (path.canFind(sep) || altsep != "" && path.canFind(altsep)) return path;
    foreach (envPath; std.algorithm.splitter(std.process.environment["PATH"], pathsep))
    {
        string absPath = std.path.join(envPath, path);
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
