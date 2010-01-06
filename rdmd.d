// Written in the D programming language.

import std.algorithm, std.c.stdlib, std.contracts, std.date,
    std.file, std.getopt,
    std.md5, std.path, std.process, std.regexp,
    std.stdio, std.string, std.typetuple;

version (Posix)
{
    enum objExt = ".o";
    enum binExt = "";
}
else version (Windows)
{
    enum objExt = ".obj";
    enum binExt = ".exe";
}
else
{
    static assert(0);
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
        args = args[0 .. 1] ~ split(a) ~ args[2 .. $];
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
            // add a trailing path separator to clarify it's a dir
            exe = std.path.join(value[1 .. $], "");
            assert(std.algorithm.endsWith(exe, std.path.sep[]));
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
        foreach (b; [ std.process.getenv("BROWSER"), "firefox",
                        "sensible-browser", "x-www-browser" ]) {
            if (!b.length) continue;
            if (!system(b~" http://www.digitalmars.com/d/2.0/rdmd.html"))
                return;
        }
    }

    bool bailout;    // bailout set by functions called in getopt if
                     // program should exit
    string[] loop;       // set by --loop
    bool addStubMain;// set by --main
    string[] eval;     // set by --eval
    getopt(args,
            std.getopt.config.caseSensitive,
            std.getopt.config.passThrough,
            std.getopt.config.stopOnFirstNonOption,
            "build-only", &buildOnly,
            "chatty", &chatty,
            "dry-run", &dryRun,
            "force", &force,
            "help", (string) { writeln(helpString); bailout = true; },
            "main", &addStubMain,
            "man", (string) { man; bailout = true; },
            "eval", &eval,
            "loop", &loop,
            "o", &dashOh,
            "compiler", &compiler);
    if (bailout) return 0;
    if (dryRun) chatty = true; // dry-run implies chatty

    // Just evaluate this program!
    if (loop)
    {
        return .eval(importWorld ~ "void main(char[][] args) { "
                ~ "foreach (line; stdin.byLine()) {\n" ~ join(loop, "\n")
                ~ ";\n} }");
    }
    if (eval)
    {
        return .eval(importWorld ~ "void main(char[][] args) {\n"
                ~ join(eval, "\n") ~ ";\n}");
    }
    
    // Parse the program line - first find the program to run
    uint programPos = 1;
    for (;; ++programPos)
    {
        if (programPos == args.length)
        {
            write(helpString);
            return 1;
        }
        if (args[programPos].length && args[programPos][0] != '-') break;
    }
    const
        root = /*rel2abs*/(chomp(args[programPos], ".d") ~ ".d"),
        exeBasename = basename(root, ".d"),
        exeDirname = dirname(root),
        programArgs = args[programPos + 1 .. $];
    args = args[0 .. programPos];
    const compilerFlags = args[1 .. programPos];

    // Compute the object directory and ensure it exists
    invariant objDir = getObjPath(root, compilerFlags);
    if (!dryRun)        // only make a fuss about objDir on a real run
    {
        exists(objDir)
            ? enforce(isdir(objDir),
                    "Entry `"~objDir~"' exists but is not a directory.")
            : mkdir(objDir);
    }
   
    // Fetch dependencies
    const myModules = getDependencies(root, objDir, compilerFlags);

    // Compute executable name, check for freshness, rebuild
    if (exe)
    {
        // user-specified exe name
        if (std.algorithm.endsWith(exe, std.path.sep[]))
        {
            // user specified a directory, complete it to a file
            exe = std.path.join(exe, exeBasename);
        }
    }
    else
    {
        //exe = exeBasename ~ '.' ~ hash(root, compilerFlags);
        version (Posix)
            exe = join(myOwnTmpDir, rel2abs(root)[1 .. $])
                ~ '.' ~ hash(root, compilerFlags);
        else version (Windows)
            exe = join(myOwnTmpDir, std.string.replace(root, ".", "-"))
                ~ '-' ~ hash(root, compilerFlags);
        else
            assert(0);
    }
    // Add an ".exe" for Windows
    exe ~= binExt; 

    // Have at it
    if (isNewer(root, exe) ||
            std.algorithm.find!
                ((string a) {return isNewer(a, exe);})
                (myModules.keys).length)
    {
        invariant result = rebuild(root, exe, objDir, myModules, compilerFlags,
                                   addStubMain);
        if (result) return result;
    }

    // run
    return buildOnly ? 0 : execv(exe, [ exe ] ~ programArgs);
}

bool inALibrary(in string source, in string object)
{
    // Heuristics: if source starts with "std.", it's in a library
    return std.string.startsWith(source, "std.")
        || std.string.startsWith(source, "core.")
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
        enum tmpRoot = "/tmp/.rdmd";
    }
    else version (Windows)
    {
        auto tmpRoot = std.process.getenv("TEMP");
        if (!tmpRoot)
        {
            tmpRoot = std.process.getenv("TMP");
        }
        if (!tmpRoot) tmpRoot = join(".", ".rdmd");
        else tmpRoot ~= sep ~ ".rdmd";
    }
    exists(tmpRoot) && isdir(tmpRoot) || mkdirRecurse(tmpRoot);
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

// Rebuild the executable fullExe starting from modules myModules
// passing the compiler flags compilerFlags. Generates one large
// object file.

private int rebuild(string root, string fullExe,
        string objDir, in string[string] myModules,
        in string[] compilerFlags, bool addStubMain)
{
    auto todo = compiler~" "~join(compilerFlags, " ")
        ~" -of"~shellQuote(fullExe)
        ~" -od"~shellQuote(objDir)
        ~" "~shellQuote(root)~" ";
    foreach (k; map!(shellQuote)(myModules.keys)) {
        todo ~= k ~ " ";
    }

    // Need to add the pesky void main(){}?
    if (addStubMain)
    {
        auto stubMain = std.path.join(myOwnTmpDir, "stubmain.d");
        std.file.write(stubMain, "void main(){}");
        todo ~= stubMain;
    }
    
    invariant result = run(todo);
    if (result) 
    {
        // build failed
        return result;
    }
    // clean up the dir containing the object file
    rmdirRecurse(objDir);
    return 0;
}

// Run a program optionally writing the command line first

private int run(string todo)
{
    if (chatty) writeln(todo);
    if (dryRun) return 0;
    return system(todo);
}

// Given module rootModule, returns a mapping of all dependees .d
// source filenames to their corresponding .o files sitting in
// directory objDir. The mapping is obtained by running dmd -v against
// rootModule.

private string[string] getDependencies(string rootModule, string objDir,
        in string[] compilerFlags)
{
    string d2obj(string dfile) {
        return std.path.join(objDir, chomp(basename(dfile), ".d")~objExt);
    }

    immutable depsFilename = rootModule~".deps";
    immutable rootDir = dirname(rootModule);
    
    // myModules maps module source paths to corresponding .o names
    string[string] myModules;// = [ rootModule : d2obj(rootModule) ];
    // Must collect dependencies
    invariant depsGetter = /*"cd "~shellQuote(rootDir)~" && "
                             ~*/compiler~" "~join(compilerFlags, " ")
        ~" -v -o- "~shellQuote(rootModule)
        ~" >"~depsFilename;
    if (chatty) writeln(depsGetter);
    immutable depsExitCode = system(depsGetter);
    if (depsExitCode)
    {
        // if (exists(depsFilename))
        // {
        //     stderr.writeln(readText(depsFilename));
        // }
        exit(depsExitCode);
    }
    auto depsReader = File(depsFilename);
    scope(exit) collectException(depsReader.close); // we don't care for errors

    // Fetch all dependent modules and append them to myModules
    auto pattern = new RegExp(r"^import\s+(\S+)\s+\((\S+)\)\s*$");
    foreach (string line; lines(depsReader))
    {
        if (!pattern.test(line)) continue;
        invariant moduleName = pattern[1], moduleSrc = pattern[2];
        if (inALibrary(moduleName, moduleSrc)) continue;
        invariant moduleObj = d2obj(moduleSrc);
        myModules[/*rel2abs*/join(rootDir, moduleSrc)] = moduleObj;
    }

    return myModules;
}

/*private*/ string shellQuote(string filename)
{
    // This may have to change under windows
    version (Windows) enum quotechar = '"';
    else enum quotechar = '\'';
    return quotechar ~ filename ~ quotechar;
}

private bool isNewer(string source, string target)
{
    return force || lastModified(source) >= lastModified(target, d_time.min);
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
  --man             open web browser on manual page
  --shebang         rdmd is in a shebang line (put as first argument)
";
}

// For --eval
immutable string importWorld = "
module temporary;
import std.stdio, std.algorithm, std.array, std.atomics, std.base64, 
    std.bigint, /*std.bind, std.bitarray,*/ std.bitmanip, std.boxer, 
    std.compiler, std.complex, std.contracts, std.conv, std.cpuid, std.cstream,
    std.ctype, std.date, std.dateparse, std.demangle, std.encoding, std.file, 
    std.format, std.functional, std.getopt, std.intrinsic, std.iterator, 
    /*std.loader,*/ std.math, std.md5, std.metastrings, std.mmfile, 
    std.numeric, std.outbuffer, std.path, std.perf, std.process, 
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

    if (exists(progname) ||
            // Compile it
            (std.file.write(progname~".d", todo),
                    run("dmd " ~ progname ~ ".d -of" ~ progname) == 0))
    {
        // It's there, just run it
        run(progname);
    }

    // Clean pathname
    enum lifetimeInHours = 24;
    auto cutoff = getUTCtime - 60 * 60 * lifetimeInHours * ticksPerSecond;
    foreach (DirEntry d; dirEntries(pathname, SpanMode.shallow))
    {
        if (d.lastWriteTime < cutoff)
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
