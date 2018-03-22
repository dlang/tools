/**
Provides hardcoded configuration settings for rdmd derived from
the target environment
*/
module rdmd.config;

/**
'Namespace' struct to encapsulate all configuration settings
fixed at compile time.  These may be hardcoded, or dependent
on the compiler or OS.
*/
struct RDMDConfig
{
  static:
    version (Posix)
    {
        /// default file extensions on POSIX systems
        enum objExt = ".o";        /// ditto
        enum binExt = "";          /// ditto
        enum libExt = ".a";        /// ditto

        /// POSIX systems only accept one dir separator,
        /// so this is empty
        enum altDirSeparator = "";
    }
    else version (Windows)
    {
        /// default file extensions on Windows systems
        enum objExt = ".obj"; /// ditto
        enum binExt = ".exe"; /// ditto
        enum libExt = ".lib"; /// ditto

        /// Windows accepts `/` as a dir separator as
        /// well as the default `\`
        enum altDirSeparator = "/";
    }
    else
    {
        static assert(0, "Unsupported operating system.");
    }

    /// packages to exclude from builds by default
    immutable string[] defaultExclusions = ["std", "etc", "core"];

    /// default D compiler that rdmd should use if none is
    /// specified with the --compiler flag
    version (DigitalMars)
        enum defaultCompiler = "dmd";   /// ditto
    else version (GNU)
        enum defaultCompiler = "gdmd";  /// ditto
    else version (LDC)
        enum defaultCompiler = "ldmd2"; /// ditto
    else
        static assert(false, "Unknown compiler");
}
