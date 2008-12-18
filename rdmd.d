// Written in the D programming language.

/*
 *  Copyright (C) 2008 by Andrei Alexandrescu
 *  Written by Andrei Alexandrescu, www.erdani.org
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

import std.getopt, std.string, std.process, std.stdio, std.contracts, std.file,
    std.algorithm, std.iterator, std.md5, std.path, std.regexp, std.getopt,
    std.c.stdlib, std.date, std.process;

private bool chatty, buildOnly, dryRun, force;
private string exe, compiler = "dmd";

int main(string[] args)
{
    //writeln("Invoked with: ", map!(q{a ~ ", "})(args));
    
    // Parse the #! line of the root module
    // Not used yet; not sure whether it's a good idea
    // completeFlagsFromShebang(root, args);

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
            assert(exe.endsWith(std.path.sep));
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

    // set by functions called in getopt if program should exit
    bool bailout;
    getopt(args,
            std.getopt.config.caseSensitive,
            std.getopt.config.passThrough,
            std.getopt.config.stopOnFirstNonOption,
            "build-only", &buildOnly,
            "chatty", &chatty,
            "dry-run", &dryRun,
            "force", &force,
            "help", (string) { writeln(helpString); bailout = true; },
            "man", (string) { man; bailout = true; },
            "o", &dashOh,
            "compiler", &compiler);
    if (bailout) return 0;
    if (dryRun) chatty = true; // dry-run implies chatty

    // Parse the program line - first find the program to run
    invariant programPos = find!("a.length && a[0] != '-'")(args[1 .. $])
        - begin(args);
    if (programPos == args.length)
    {
        write(helpString);
        return 1;
    }
    const
        root = /*rel2abs*/(chomp(args[programPos], ".d") ~ ".d"),
        exeBasename = basename(root, ".d"),
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
        if (endsWith(exe, std.path.sep))
        {
            // user specified a directory, complete it to a file
            exe = std.path.join(exe, exeBasename);
        }
    }
    else
    {
        exe = exeBasename ~ '.' ~ hash(root, compilerFlags);
    }

    // Have at it
    if (isNewer(root, exe) ||
            canFind!((string a) {return isNewer(a, exe);})(myModules.keys))
    {
        invariant result = rebuild(root, exe, objDir, myModules, compilerFlags);
        if (result) return result;
    }

    // run
    return buildOnly ? 0 : execv(exe, [ exe ] ~ programArgs);
}

bool inALibrary(in string source, in string object)
{
    // Heuristics: if source starts with "std.", it's in a library
    return startsWith(source, "std.") || startsWith(source, "core.")
        || source == "object" || source == "gcstats";
    // another crude heuristic: if a module's path is absolute, it's
    // considered to be compiled in a separate library. Otherwise,
    // it's a source module.
    //return isabs(mod);
}

private string tmpDir()
{
    version (linux)
    {
        enum tmpRoot = "/tmp";
    }
    else version (Windows)
    {
        auto tmpRoot = std.process.getenv("TEMP");
        if (!tmpRoot)
        {
            tmpRoot = std.process.getenv("TMP");
            if (!tmpRoot) tmpRoot = ".";
        }
    }
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
        if (canFind(irrelevantSwitches, flag)) continue;
        context.update(flag);
    }
    ubyte digest[16];
    context.finish(digest);
    return digestToString(digest);
}

private string getObjPath(in string root, in string[] compilerFlags)
{
    const tmpRoot = tmpDir;
    return std.path.join(tmpRoot,
            "rdmd-" ~ basename(root) ~ '-' ~ hash(root, compilerFlags));
}

// Rebuild the executable fullExe starting from modules myModules
// passing the compiler flags compilerFlags. Generates one large
// object file.

private int rebuild(string root, string fullExe,
        string objDir, in string[string] myModules,
        in string[] compilerFlags)
{
    invariant todo = compiler~" "~join(compilerFlags, " ")
        ~" -of"~shellQuote(fullExe)
        ~" -od"~shellQuote(objDir)
        ~" "~shellQuote(root)~" "
        ~join(map!(shellQuote)(myModules.keys), " ");
    invariant result = run(todo);
    if (result) 
    {
        // build failed
        return result;
    }
    // clean up the object file, not needed anymore
    //remove(std.path.join(objDir, basename(root, ".d")~".o"));
    // clean up the dir containing the object file
    rmdirRecurse(objDir);
    return 0;
}

void completeFlagsFromShebang(string root, ref string[] args)
{
    auto f = File(root);
    auto sheBang = f.readln;
    auto cmd = std.regexp.split(strip(sheBang), r"\s+");
    if (cmd.length <= 1 || !cmd[0].startsWith("#!")) return;
    invariant prog = cmd[0][2 .. $];

    // Allowed shebangs:
    // #!/path/to/rdmd --stuff
    // or
    // #!/usr/bin/env rdmd --stuff
    // or
    // #!/bin/env rdmd --stuff
    if (basename(prog) != "rdmd")
    {
        if (prog != "/bin/env" && prog != "/usr/bin/env" || cmd[1] != "rdmd")
            return;
        // Discard the "[/usr]/bin/env" thing
        cmd = cmd[1 .. $];
    }
    // Ok, found a command with maybe some parms. Put those in front so
    // they are overridden by the true command-line arguments
    args = args[0] ~ cmd[1 .. $] ~ args[1 .. $];
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
        return std.path.join(objDir, chomp(basename(dfile), ".d")~".o");
    }
    
    // myModules maps module source paths to corresponding .o names
    string[string] myModules;// = [ rootModule : d2obj(rootModule) ];
    // Must collect dependencies
    invariant depsGetter = compiler~" "~join(compilerFlags, " ")
        ~" -v -o- "~shellQuote(rootModule);
    if (chatty) writeln(depsGetter);
    File depsReader;
    depsReader.popen(depsGetter);
    scope(exit) collectException(depsReader.close); // we don't care for errors

    // Fetch all dependent modules and append them to myModules
    auto pattern = new RegExp(r"^import\s+(\S+)\s+\((\S+)\)\s*$");
    foreach (string line; lines(depsReader))
    {
        if (!pattern.test(line)) continue;
        invariant moduleName = pattern[1], moduleSrc = pattern[2];
        if (inALibrary(moduleName, moduleSrc)) continue;
        invariant moduleObj = d2obj(moduleSrc);
        myModules[/*rel2abs*/(moduleSrc)] = moduleObj;
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
"Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]...
Builds (with dependents) and runs a D program.
Example: rdmd -release myprog --myprogparm 5

Any option to be passed to dmd must occur before the program name. In addition
to dmd options, rdmd recognizes the following options:
  --build-only      just build the executable, don't run it
  --chatty          write dmd commands to stdout before executing them
  --compiler=comp   use the specified compiler (e.g. gdmd) instead of dmd
  --dry-run         do not compile, just show what commands would be run
                      (implies --chatty)
  --force           force a rebuild even if apparently not necessary
  --help            this message
  --man             open web browser on manual page
";
}
