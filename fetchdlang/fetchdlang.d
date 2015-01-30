/**

        fetchdlang: a tool for building and maintaining the dlang toolchain from github
                    for the D programming language

                    ported from update.sh by Laeeth Isharc 2015

        Boost license, but as far as I am concerned do as you wish,
        with this, and at your own risk be it!

        I stuck to structure of original script for clarity.  Obviously
        it would be better to factor out common repeated code and use
        a table for list of projects and git/make instructions for each.

        Not yet tested on FreeBSD or OSX.  Needs minor work for Windows
    */


module updatesh;
import std.stdio;
import std.typecons : Tuple, tuple;

debug = 0;
enum verbose = true;
enum projects = ["dmd","druntime","phobos","dlang.org","tools","installer"];
enum makeCommand = "make";
enum parallelCores = "8";
enum modelArchitecture = "64";

version(Posix)
    enum makeFilename = "posix.mak";
else version(Windows)
{
    enum makeFilename = "windows.mak";
    pragma(msg,"* warning - windows build is untested and probably needs tweaking before it will work");
}
else
    static assert(0,"fetchdlang currently only supports Posix or Windows");

enum ResultType
{
    failure,
    success,
}

enum helpText =
    "
   
    https://github.com/D-Programming-Language/tools/blob/master/update.sh
    
    1. create a working directory where the source files are to be installed
    2. change to this directory
    3. run fetchdlang from this directory.
       eg /usr/sbin/fetchdlang when you are in /opt/dlangdev
    

    The following subdirectories will be created, each containing the latest
    sources from github:
        dmd,druntime,phobos,dlang.org,tools,installer
    
    After source has been fetched, the tool will build each component in turn.

    On on ongoing basis, to update your toolchain from github, go to the same
    directory and run fetchdlang again.  fetchdlang will detect that directories
    exist and will do an update.";

enum argumentHelpText = 
"    Arguments
    ---------
    No arguments are required, but the following are options:

    install:      copy the D compiler from the dmd build directory and replace
                  local binary install
                  *** not advisable *** unless you know what you are doing, as
                  you may break your local DMD

    onlyinstall:  do not fetch or build anything - locally install dmd binaries
                  from build directory

    --tag=XYZ:    fetch, build, and (optionallly install) a tagged version from
                  the repositories.
                  Eg --tag = 2.067.0-b1 for DMD beta 2.067 beta 1.  This will
                  prepend the tag argumeny by 'v' and fetch v2.067-0-b1 from git.

    --cleanlocks: Only use this if you are sure you know what you are doing. 
                  Incomplete git fetch may lock some of the repositories.  In
                  this case, to update them you will need to remove the
                  .git/index.lock file that it leaves behind.  This option
                  removes the lock, but can cause problems if the reason for the
                  lock is that a concurrent instance of git is running.";


debug
{
    void log(string msg)
    {
        stderr.writefln(msg);
    }
}

struct Params
{
    bool cleanLocks = false;
    string tag;
    bool installDMD = false;
    bool onlyInstall = false;
    string workingDir;
    string tempDir;
    string[] toUpdate;
    string[] toInstall;
}

int main(string[] args)
{
    import std.path : dirSeparator;
    import scriptutil : makeTempDir;
    import std.string : indexOf;
    import std.file: getcwd, tempDir, mkdirRecurse, rmdirRecurse;

    Params params;
    params.tempDir = makeTempDir(tempDir() ~ dirSeparator ~ "dmd-update.XXX"); // working directory
    params.workingDir = getcwd();

// Take care of the command line arguments
    writefln("* fetchdlang: a tool for building and maintaining the dlang toolchain from github");
    foreach(arg; args[1 .. $])
    {
        if ((arg == "-h") || (arg == "-H"))
        {
            printHelp();
            return 0;
        }
        
        else if ((arg == "-hh") || (arg=="-HH"))
        {
            printFullHelp();
            return 0;
        }
        
        else if ((arg.length >= 4) && (arg[0 .. 5] == "--tag"))
        {
            auto m = arg.indexOf(" = ");
            if (arg.length-1 > m)
            {
                params.tag ~= arg[m+1 .. $];
            }
            else
            {
                stderr.writefln("* syntax is --tag = tagname\n\n");
                printHelp();
                return 1;
            }
        }
        else if ((arg == "install") || (arg == "onlyinstall"))
        {
            params.installDMD = true;
            if (arg == "onlyinstall")
                {writefln("* Only installing DMD; will not update or download from git"); params.onlyInstall = true;};
        }
        else if (arg == "--cleanlocks")
        {
            writefln("\n\n* cleaning up git locks - I hope you made sure git was not running already in subdirectories\n");
            params.cleanLocks = true;
        }
        else
        {
            stderr.writefln("\n\n*****     Error - argument: " ~ arg ~ " not recognized.\n\n");
            printHelp();
            return 1;
        }
    }

    if (params.tag.length != 0)
    {
        params.workingDir ~= dirSeparator ~ params.tag;
        mkdirRecurse(params.workingDir);
    }


    with (ResultType)
    {
        if ((confirmChoices(params) == success)
            && (installAnew(params) == success)
            && (update(params) == success)
            &&(makeWorld(params) == success))
                {stdout.flush;stderr.flush; rmdirRecurse(params.tempDir); return 1;}
    }
    writefln("some operations failed: log files are at %s",params.tempDir);
    return 0;
}



// Confirm correct choices
ResultType confirmChoices(ref Params params)
{
    import std.algorithm : map;
    import std.path : dirSeparator;
    import std.string : toLower, strip;
    import std.file : exists, isDir;
    import std.array : array, join;

    if (params.onlyInstall)
    {
        writefln("*** installing DMD from build directory to system DMD\n");
    }
    else
    {
        foreach(project; projects)
        {
            auto projectPath = params.workingDir ~ dirSeparator ~ project;
            if (exists(projectPath) && isDir(projectPath))
                params.toUpdate ~= project;
            else
                params.toInstall ~= project;
        }

        if ((params.toInstall.length == 0) && (params.toUpdate.length == 0)) // shoudn't happen
        {
            stderr.writefln("* Nothing to do.  (Quitting\n\n");
            printHelp();
            return ResultType.failure;
        }

        if (params.toInstall.length > 0)
        {
            writefln("\n\n*** The following projects will be INSTALLED:");
            writef(params.toInstall.map!(a => "\t" ~ params.workingDir ~ dirSeparator ~ a).array.join("\n"));
            writefln("\n*** Note: this script assumes you have a github account set up.");
        }

        if (params.toUpdate.length > 0)
        {
            writefln("\n\n*** The following projects will be UPDATED:");
            writef(params.toUpdate.map!(a => "\t" ~ params.workingDir ~ dirSeparator ~ a).array.join("\n"));
        }
    }   
    writefln("\n\nIs this what you want? (yes/no)");
    while (true)
    {
        auto resp = readln().toLower();
        switch(strip(resp))
        {
            case "yes":
                break;

            case "no":
                writefln("* Okay - quitting now");
                return ResultType.failure;

            default:
                writefln("* Please answer yes or no");
                continue;
        }
        break;
    }
    writefln("\n\n");
    return ResultType.success;
}






void printHelp()
{
     writefln(helpText);
     writefln("\nNo arguments are required, but use -hh argument for details of options\n");
}

void printFullHelp()
{
    writefln(helpText);
    writefln("\n" ~ argumentHelpText ~ "\n");
}


/**
    Install from scratch
*/


ResultType installAnew(ref Params params)
{
    import std.process : executeShell;
    import std.path : dirSeparator;
    import std.string : canFind;
    import std.file : exists, chdir, isDir;

    string[] failedInstalls;

    if (params.onlyInstall)
        return ResultType.success;

    foreach(project; params.toInstall)
    {
        chdir(params.workingDir);

        debug log("executeShell git clone --quiet git://github.com/D-Programming-Language/" ~ project ~ ".git");
        auto result = executeShell("git clone --quiet git://github.com/D-Programming-Language/" ~ project ~ ".git");
        if ((result.status != 0) || (!exists(project)) || (!isDir(project))) // paranoia - of course it is a directory
            failedInstalls ~= project;
        debug log("result was " ~ (result.output.length > 0)?result.output:"successful");
    }

    if (failedInstalls.length)
    {
        foreach(fail; failedInstalls)
        {
            stderr.writefln("Getting "~fail~ " failed");
        }
        return ResultType.failure;
    }

    foreach(project; params.toInstall)
    {
        auto ourPath = params.workingDir ~ dirSeparator ~ project;
        if ((params.tag.length > 0) && (canFind(["dmd","druntime","phobos","dlang.org"],project)))
        {
            chdir(params.workingDir ~ dirSeparator~project);
            if (executeShell("git checkout v"~params.tag).status != 0)
            {
                stderr.writefln("* warning: unable to checkout " ~ project ~ " v" ~ params.tag);
                stderr.writefln("* soldiering on");
            }
        }
    }
    return ResultType.success;
}

/**
    Freshen existing stuff
*/


ResultType update(Params params)
{
    import std.parallelism;
    import std.path : dirSeparator;
    import std.file : chdir;

    if (params.onlyInstall)
        return ResultType.success;
    writefln("Updating projects in " ~ params.workingDir ~ " ...");


    ResultType updateProject(immutable string project,immutable bool cleanLocks)
    {
        import std.process : executeShell;
        string gitproject = "git://github.com/D-Programming-Language/" ~ project ~".git";
        chdir(params.workingDir ~ dirSeparator ~ project);
        if (cleanLocks)
            {writefln("* removing following lock: %s/.git/index.lock",project); remove(".git/index.lock");}

        auto result = executeShell("git checkout master");
        if (result.status == 0)
        {
            result = executeShell("git pull --ff-only " ~ gitproject ~ " master");
            if (result.status == 0)
            {
                 result = executeShell("git pull " ~ gitproject ~ " master --tags");
                 if (result.status == 0)
                 {
                    result = executeShell("git fetch " ~ gitproject);
                    if (result.status == 0)
                    {
                        result = executeShell("git fetch --tags " ~ gitproject);
                        if (result.status == 0)
                        {
                            return ResultType.success;
                        }
                    }
                }
             }
        }

        auto f = File(params.tempDir ~ dirSeparator ~ project ~ ".log","w+");
        f.writef("\n" ~ result.output ~ "\n");
        stderr.writefln("failure updating " ~ params.workingDir ~ dirSeparator ~ project ~ ": git output was: "~result.output);
        return ResultType.failure;
    }

    bool failed = false;

    foreach(project; parallel(params.toUpdate))
    {
        failed |= (updateProject(project,params.cleanLocks) == ResultType.failure);
    }

    return failed?ResultType.failure:ResultType.success;
}



ResultType makeWorld(Params params)
{
    import std.process : executeShell;
    import std.path : dirSeparator;
    import scriptutil : universalWhich, amIRoot, joinPath, fileIsWritable, fileExists;
    import std.file : chdir;


    // First make dmd
    chdir(joinPath([params.workingDir,"dmd" ,"src"]));
    if (!params.onlyInstall)
    {
        if (verbose)
            writefln("* Making dmd");
        if ((executeShell(makeCommand ~ " -f "~makeFilename~" clean modelArchitecture=" ~ modelArchitecture).status != 0) ||
            (executeShell(makeCommand ~ " -f "~makeFilename~ " -j " ~ parallelCores ~ " modelArchitecture=" ~ modelArchitecture).status != 0))
                {stderr.writefln("* Failed to make dmd: aborting"); return ResultType.failure;};
    }
// Update the running dmd version
    if (params.installDMD)
    {
        if (verbose)
            writefln("* Updating installed DMD");
        auto locateOldDMD = universalWhich("dmd");
        if (!locateOldDMD.success)
        {
            stderr.writefln("* unable to locate existing DMD installation with the following error: "~locateOldDMD.result);
            stderr.writefln("* skipping the update step");
        }
        else
        {
            if (fileExists(locateOldDMD.result))
            {
                writefln("* Copying " ~ joinPath([params.workingDir,"dmd","src","dmd"])~" over "~locateOldDMD.result);
                string sudo = "";
                if (!fileIsWritable(locateOldDMD.result) && (amIRoot())) // not exactly correct - we should check directly if run as sudo
                    sudo = "sudo ";
                debug
                {
                    stderr.writefln("pretending to execute: " ~ sudo~ "cp "~joinPath([params.workingDir,"dmd","src","dmd"]) ~ " " ~ locateOldDMD.result);
                }
                else // non-debug
                {
                    auto result = executeShell(sudo ~ "cp " ~ joinPath([params.workingDir,"dmd","src","dmd"]) ~ " " ~ locateOldDMD.result);
                    if (result.status != 0)
                        stderr.writefln("* Unable to copy over new dmd to old version; failed with error " ~ result.output ~ " but will soldier on");
                }
            }
            if (params.onlyInstall)
                return ResultType.success;
        }
    }

// Then make druntime
    chdir(params.workingDir ~ dirSeparator ~ "druntime");
    if (verbose)
        writefln("* Making druntime");
    if (executeShell(makeCommand ~ " -f "~makeFilename ~ " -j " ~ parallelCores ~ " DMD=" ~ joinPath([params.workingDir,"dmd","src","dmd"]) ~ " modelArchitecture=" ~ modelArchitecture).status != 0)
        {stderr.writefln("* Failed to make druntime: aborting"); return ResultType.failure;};       

// Then make phobos
    chdir(params.workingDir~dirSeparator~"phobos");
    if (verbose)
        writefln("* Making phobos");
    if (executeShell(makeCommand ~ " -f " ~ makeFilename ~ " -j " ~ parallelCores ~ " DMD=" ~ joinPath([params.workingDir,"/dmd","src","dmd"]) ~ " modelArchitecture=" ~ modelArchitecture).status != 0)
        {stderr.writefln("* Failed to make phobos: aborting"); return ResultType.failure;};       

// Then make website

    if (verbose)
        writefln("* Making website");
    if ((executeShell(makeCommand ~ " -f " ~ makeFilename ~ " clean "~" DMD=" ~ joinPath([params.workingDir,"dmd","src","dmd"]) ~ " modelArchitecture=" ~ modelArchitecture).status != 0) ||
        (executeShell(makeCommand ~ " -f " ~ makeFilename ~ " -j " ~ parallelCores ~ " DMD=" ~ joinPath([params.workingDir,"dmd","src","dmd"]) ~ " modelArchitecture=" ~ modelArchitecture).status != 0))
        {stderr.writefln("* Failed to make dlang.org: aborting"); return ResultType.failure;};       
    if (verbose)
        writefln("* Make process was successful");

    return ResultType.success;
}

