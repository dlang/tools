/**
Provides functionality via which rdmd interacts with the filesystem
*/
module rdmd.filesystem;

/**
Used to wrap filesystem operations that should also be logged with the
yap function or affected by dryRun. Append the string "IfLive" to the end
of the function for it to be skipped during a dry run.

These functions allow the filename to be given once so the log statement
always matches the operation. Using it also guarantees you won't forget to
include a `yap` alongside any file operation you want to be logged.
*/
struct Filesystem
{
  static:
    static auto opDispatch(string func, T...)(T args)
    {
        import std.algorithm.searching : endsWith;

        static if (func.endsWith("IfLive"))
        {
            enum fileFunc = func[0 .. $ - "IfLive".length];
            enum skipOnDryRun = true;
        }
        else
        {
            enum fileFunc = func;
            enum skipOnDryRun = false;
        }

        import rdmd.verbose : yap;
        import std.algorithm.comparison : among;

        static if (fileFunc.among("exists", "timeLastModified", "isFile", "isDir", "existsAsFile"))
            yap("stat ", args[0]);
        else static if (fileFunc == "rename")
            yap("mv ", args[0], " ", args[1]);
        else static if (fileFunc.among("remove", "mkdirRecurse", "rmdirRecurse", "dirEntries", "write", "touchEmptyFile"))
            yap(fileFunc, " ", args[0]);
        else static assert(0, "Filesystem.opDispatch has not implemented " ~ fileFunc);

        static if (skipOnDryRun)
        {
            import rdmd.args : RDMDGlobalArgs;
            if (RDMDGlobalArgs.dryRun)
                return;
        }
        mixin("return DirectFilesystem." ~ fileFunc ~ "(args);");
    }

    /**
    Operates on the file system without logging its operations or being
    affected by dryRun.
    */
    private static struct DirectFilesystem
    {
      static:
        import file = std.file;
        alias file this;

        /**
        Update an empty file's timestamp.
        */
        static void touchEmptyFile(string name)
        {
            file.write(name, "");
        }
        /**
        Returns true if name exists and is a file.
        */
        static bool existsAsFile(string name)
        {
            return file.exists(name) && file.isFile(name);
        }
    }
}
