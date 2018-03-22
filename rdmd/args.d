/**
Provides functionality for parsing command-line arguments and data
structures for storing the results
*/
module rdmd.args;

import rdmd.config : RDMDConfig;

/**
'Namespace' struct to encapsulate all global settings derived
from command-line arguments to `rdmd`
*/
struct RDMDGlobalArgs
{
  static:
    bool chatty;  /// verbose output
    bool buildOnly;  /// only build programs, do not run
    bool dryRun; /// do not compile, just show what commands would run
    bool force; /// force a rebuild even if not necessary
    bool preserveOutputPaths; /// preserve source path for output files

    string exe; /// output path for generated executable
    string userTempDir; /// temporary directory to use instead of default

    string[] exclusions = RDMDConfig.defaultExclusions; /// packages that are to be excluded
    string[] extraFiles = []; /// paths to extra source or object files to include

    string compiler = RDMDConfig.defaultCompiler; /// D compiler to use
}
