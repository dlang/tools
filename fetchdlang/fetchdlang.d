/**

		Ported to the D Programming language by Laeeth Isharc 2014
		Boost license, but as far as I am concerned do as you wish,
		with this, and at your own risk be it!

		I stuck to structure of original script for clarity.  Obviously
		it would be better to factor out common repeated code and use
		a table for list of projects and git/make instructions for each.

		Not yet tested on Windows
	*/

/**
	Run this script to install or update your dmd toolchain from
	github.

	Make sure zsh is installed. You may need to change the shebang.

	First run, create a working directory, e.g. /path/to/d/. Then run
	this script from that directory (the location of the script itself
	doesn't matter). It will create the following subdirectories:
	path/to/d/dmd, /path/to/d/druntime, /path/to/d/phobos,
	path/to/d/dlang.org, /path/to/d/tools, and
	/path/to/d/installer. Then it will fetch all corresponding projects
	from github and build them fresh.

	On an ongoing basis, to update your toolchain from github go again
	to the same directory (in our example /path/to/d) and run the script
	again. The script will detect that directories exist and will do an
	update.
*/

module updatesh;
import std.stdio;
import std.typecons : Tuple,tuple;

debug=0;
enum verbose=true;
enum Projects=["dmd","druntime","phobos","dlang.org","tools","installer"];
enum MakeCommand="make";
enum ParallelCores="8";
enum ModelArchitecture="64";

version(Posix)
	enum MakefileName="posix.mak";
else version(Windows)
{
	enum MakefileName="windows.mak";
	pragma(msg,"* warning - windows build is untested and probably needs tweaking before it will work");
}
else
	static assert(0,"fetchdlang currently only supports Posix or Windows");



enum ResultType
{
	Failure,
	Success,
}

debug
{
	void log(string msg)
	{
		stderr.writefln(msg);
	}
}

struct Params
{
	bool cleanLocks=false;
	string tag;
	bool installDMD=false;
	bool onlyInstall=false;
	string workingDir;
	string tempDir;
	string[] toUpdate;
	string[] toInstall;
}

int main(string[] args)
{
	import std.path : dirSeparator;
	import scriptutil : TempDirMode,makeTempEntry;
	import std.string : indexOf;
	import std.file: getcwd,tempDir,mkdirRecurse,rmdirRecurse;

	Params params;
	params.tempDir=makeTempEntry(tempDir() ~ dirSeparator ~ "dmd-update.XXX",TempDirMode.createDirectory); // working directory
	params.workingDir=getcwd();

// Take care of the command line arguments
	writefln("* fetchdlang: a tool for updating DMD build from github\n");
	foreach(arg;args[1..$])
	{
    	if (arg[0..5]=="--tag")
    	{
    		auto m=arg.indexOf("=");
    		if (arg.length-1>m)
    		{
    			params.tag~=arg[m+1..$];
    		}
    		else
    		{
    			stderr.writefln("* syntax is --tag=tagname\n\n");
    			printHelp();
    			return 1;
    		}
    	}
    	else if ((arg=="install") || (arg=="onlyinstall"))
    	{
           	params.installDMD=true;
           	if (arg=="onlyinstall")
           		{writefln("* Only installing DMD; will not update or download from git"); params.onlyInstall=true;};
    	}
    	else if (arg=="--cleanlocks")
    	{
    		writefln("\n\n* cleaning up git locks - I hope you made sure git was not running already in subdirectories\n");
    		params.cleanLocks=true;
    	}
        else
        {
        	stderr.writefln("Error: " ~ arg ~ " not recognized.\n\n");
        	printHelp();
   	    	return 1;
        }
    }

    if (params.tag.length!=0)
    {
    	params.workingDir~=dirSeparator~params.tag;
    	mkdirRecurse(params.workingDir);
    }


	with (ResultType)
	{
		if ((confirmChoices(params)==Success)
			&& (installAnew(params)==Success)
		  	&& (update(params)==Success)
		   	&&(makeWorld(params)==Success))
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
    import std.string : toLower,strip;
    import std.file : exists, isDir;
    import std.array : array, join;

	if (params.onlyInstall)
    {
    	writefln("*** installing DMD from build directory to system DMD\n");
    }
    else
    {
	    foreach(project;Projects)
	    {
	    	auto projectPath=params.workingDir~dirSeparator~project;
	    	if (exists(projectPath)&&isDir(projectPath))
	            params.toUpdate~=project;
	        else
	            params.toInstall~=project;
	    }

	    if ((params.toInstall.length==0) && (params.toUpdate.length==0)) // shoudn't happen
	    {
	    	stderr.writefln("* Nothing to do.  (Quitting\n\n");
	    	printHelp();
	    	return ResultType.Failure;
	    }

	    if (params.toInstall.length>0)
	    {
	    	writefln("\n\n*** The following projects will be INSTALLED:");
	    	writef(params.toInstall.map!(a=>"\t"~params.workingDir~dirSeparator~a).array.join("\n"));
			writefln("\n*** Note: this script assumes you have a github account set up.");
		}

		if (params.toUpdate.length>0)
	    {
	    	writefln("\n\n*** The following projects will be UPDATED:");
	    	writef(params.toUpdate.map!(a=>"\t"~params.workingDir~dirSeparator~a).array.join("\n"));
		}
	}	
    writefln("\n\nIs this what you want? (yes/no)");
    while (true)
    {
    	auto resp=readln().toLower();
    	switch(strip(resp))
    	{
    		case "yes":
    			break;

    		case "no":
    			writefln("* Okay - quitting now");
    			return ResultType.Failure;

    		default:
    			writefln("* Please answer yes or no");
    			continue;
    	}
    	break;
    }
    writefln("\n\n");
   	return ResultType.Success;
}



void printHelp()
{
	 writefln(
 	"fetchdlang - for the D programming language
	

	https://github.com/D-Programming-Language/tools/blob/master/update.sh
	


	First run, create a working directory, e.g. /path/to/d/. Then run
	this script from that directory (the location of the script itself
	doesn't matter). It will create the following subdirectories:
	/path/to/d/dmd, /path/to/d/druntime, /path/to/d/phobos,
	/path/to/d/dlang.org, /path/to/d/tools, and
	/path/to/d/installer. Then it will fetch all corresponding projects
	from github and build them fresh.

	On an ongoing basis, to update your toolchain from github go again
	to the same directory (in our example /path/to/d) and run the script
	again. The script will detect that directories exist and will do an
	update.

"	);
}

/**
	Install from scratch
*/


ResultType installAnew(ref Params params)
{
	import std.process : executeShell;
	import std.path : dirSeparator;
	import std.string : canFind;
	import std.file : exists,chdir;

	string[] failedInstalls;

	if (params.onlyInstall)
		return ResultType.Success;

    foreach(project;params.toInstall)
    {
    	chdir(params.workingDir);

    	debug log("executeShell git clone --quiet git://github.com/D-Programming-Language/"~project~".git");
		auto result=executeShell("git clone --quiet git://github.com/D-Programming-Language/"~project~".git");
		if ((result.status!=0) || (!exists(project)) ||(!isDir(project))) // paranoia - of course it is a directory
			failedInstalls~=project;
		debug log("result was "~(result.output.length>0)?result.output:"successful");
	}

	if (failedInstalls.length)
	{
		foreach(fail;failedInstalls)
		{
			stderr.writefln("Getting "~fail~ " failed");
		}
		return ResultType.Failure;
	}

    foreach(project;params.toInstall)
    {
		auto ourPath=params.workingDir~dirSeparator~project;
        if ((params.tag.length>0) && (canFind(["dmd","druntime","phobos","dlang.org"],project)))
        {
        	chdir(params.workingDir~dirSeparator~project);
        	if (executeShell("git checkout v"~params.tag).status!=0)
        	{
        		stderr.writefln("* warning: unable to checkout "~project~" v"~params.tag);
        		stderr.writefln("* soldiering on");
        	}
        }
    }
    return ResultType.Success;
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
		return ResultType.Success;
	writefln("Updating projects in " ~ params.workingDir ~ " ...");


    ResultType updateProject(immutable string project,immutable bool cleanLocks)
    {
		import std.process : executeShell;
        string gitproject="git://github.com/D-Programming-Language/" ~ project ~".git";
        chdir(params.workingDir ~ dirSeparator ~project);
        if (cleanLocks)
        	{writefln("* removing following lock: %s/.git/index.lock",project); remove(".git/index.lock");}

        auto result=executeShell("git checkout master");
        if (result.status==0)
        {
         	result=executeShell("git pull --ff-only "~gitproject~" master");
         	if (result.status==0)
         	{
	             result=executeShell("git pull "~gitproject~" master --tags");
	             if (result.status==0)
	             {
	             	result=executeShell("git fetch "~gitproject);
			 		if (result.status==0)
			 		{
			 			result=executeShell("git fetch --tags "~gitproject);
						if (result.status==0)
						{
			 				return ResultType.Success;
			 			}
			 		}
			 	}
			 }
		}

		auto f=File(params.tempDir~dirSeparator~project~".log","w+");
		f.writef("\n"~result.output~"\n");
		stderr.writefln("Failure updating "~params.workingDir~dirSeparator~project~ ": git output was: "~result.output);
        return ResultType.Failure;
    }

    bool failed=false;

    foreach(project;parallel(params.toUpdate))
    {
    	failed |= (updateProject(project,params.cleanLocks)==ResultType.Failure);
    }

    return failed?ResultType.Failure:ResultType.Success;
}



ResultType makeWorld(Params params)
{
	import std.process : executeShell;
	import std.path : dirSeparator;
	import scriptutil : universalWhich,amIRoot,joinPath, fileIsWritable,fileExists;
	import std.file : chdir;


	// First make dmd
	chdir(joinPath([params.workingDir,"dmd" ,"src"]));
	if (!params.onlyInstall)
	{
		if (verbose)
			writefln("* Making dmd");
		if ((executeShell(MakeCommand ~ " -f "~MakefileName~" clean ModelArchitecture="~ModelArchitecture).status!=0) ||
			(executeShell(MakeCommand ~ " -f "~MakefileName~ " -j " ~ ParallelCores ~" ModelArchitecture="~ModelArchitecture).status!=0))
				{stderr.writefln("* Failed to make dmd: aborting"); return ResultType.Failure;};
	}
// Update the running dmd version
    if (params.installDMD)
    {
    	if (verbose)
    		writefln("* Updating installed DMD");
        auto locateOldDMD=universalWhich("dmd");
        if (!locateOldDMD.success)
        {
        	stderr.writefln("* unable to locate existing DMD installation with the following error: "~locateOldDMD.result);
        	stderr.writefln("* skipping the update step");
        }
        else
        {
			if (fileExists(locateOldDMD.result))
			{
				writefln("* Copying "~joinPath([params.workingDir,"dmd","src","dmd"])~" over "~locateOldDMD.result);
				string sudo="";
				if (!fileIsWritable(locateOldDMD.result) &&(amIRoot())) // not exactly correct - we should check directly if run as sudo
					sudo="sudo ";
				debug
				{
					stderr.writefln("pretending to execute: " ~ sudo~ "cp "~joinPath([params.workingDir,"dmd","src","dmd"])~" "~locateOldDMD.result);
				}
				else // non-debug
				{
					auto result=executeShell(sudo~ "cp "~joinPath([params.workingDir,"dmd","src","dmd"])~" "~locateOldDMD.result);
					if (result.status!=0)
						stderr.writefln("* Unable to copy over new dmd to old version; failed with error "~result.output ~ " but will soldier on");
				}
			}
			if (params.onlyInstall)
				return ResultType.Success;
		}
	}

// Then make druntime
	chdir(params.workingDir~dirSeparator~"druntime");
	if (verbose)
		writefln("* Making druntime");
	if (executeShell(MakeCommand ~ " -f "~MakefileName~" -j "~ParallelCores~" DMD="~joinPath([params.workingDir,"dmd","src","dmd"])~" ModelArchitecture="~ModelArchitecture).status!=0)
		{stderr.writefln("* Failed to make druntime: aborting"); return ResultType.Failure;};       

// Then make phobos
	chdir(params.workingDir~dirSeparator~"phobos");
	if (verbose)
		writefln("* Making phobos");
	if (executeShell(MakeCommand ~ " -f "~MakefileName~" -j "~ParallelCores~" DMD="~joinPath([params.workingDir,"/dmd","src","dmd"])~" ModelArchitecture="~ModelArchitecture).status!=0)
		{stderr.writefln("* Failed to make phobos: aborting"); return ResultType.Failure;};       

// Then make website

	if (verbose)
		writefln("* Making website");
	if ((executeShell(MakeCommand ~ " -f "~MakefileName~" clean "~" DMD="~joinPath([params.workingDir,"dmd","src","dmd"])~" ModelArchitecture="~ModelArchitecture).status!=0) ||
		(executeShell(MakeCommand ~ " -f "~MakefileName~" -j "~ParallelCores~" DMD="~joinPath([params.workingDir,"dmd","src","dmd"])~" ModelArchitecture="~ModelArchitecture).status!=0))
		{stderr.writefln("* Failed to make dlang.org: aborting"); return ResultType.Failure;};       
	if (verbose)
		writefln("* Make process was successful");

	return ResultType.Success;
}

