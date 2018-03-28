/**
Provides functionality for verbose rdmd output
*/
module rdmd.verbose;

void yap(size_t line = __LINE__, T...)(auto ref T stuff)
{
    import rdmd.args : RDMDGlobalArgs;
    import std.stdio : stderr;
    if (!RDMDGlobalArgs.chatty) return;
    debug stderr.writeln(line, ": ", stuff);
    else stderr.writeln(stuff);
}
