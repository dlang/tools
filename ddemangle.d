/**
 * An improved D symbol demangler.
 *
 * Replaces *all* occurrences of mangled D symbols in the input with their
 * unmangled form, and writes the result to standard output.
 *
 * Copyright: Copyright H. S. Teoh 2012.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   H. S. Teoh
 */

import core.demangle;
import std.algorithm : equal, map;
import std.getopt;
import std.regex;
import std.stdio;
import std.c.stdlib;

void showhelp(string[] args)
{
    stderr.writef(q"ENDHELP
Usage: %s [options] [<inputfile>]
Demangles all occurrences of mangled D symbols in the input and writes to
standard output.
If <inputfile> is omitted, standard input is read.
Options:
    --help, -h    Show this help
ENDHELP", args[0]);

    exit(1);
}

auto reDemangle = regex(r"\b(_D[0-9a-zA-Z_]+)\b");

auto ddemangle(T)(T line)
    if (is(T : const(char)[]))
{
    return replaceAll!(a => demangle(a.hit))(line, reDemangle);
}

unittest
{
    string[] testData = [
        "_D2rt4util7console8__assertFiZv",
        "random initial junk _D2rt4util7console8__assertFiZv random trailer",
        "multiple _D2rt4util7console8__assertFiZv occurrences _D2rt4util7console8__assertFiZv",
    ];
    string[] expected = [
        "void rt.util.console.__assert(int)",
        "random initial junk void rt.util.console.__assert(int) random trailer",
        "multiple void rt.util.console.__assert(int) occurrences void rt.util.console.__assert(int)",
    ];

    assert(equal(testData.map!ddemangle(), expected));
}

void main(string[] args)
{
    // Parse command-line arguments
    try
    {
        getopt(args,
            "help|h", { showhelp(args); },
        );
        if (args.length > 2) showhelp(args);
    }
    catch(Exception e)
    {
        stderr.writeln(e.msg);
        stderr.writeln();
        showhelp(args);
    }

    // Process input
    try
    {
        auto f = (args.length==2) ? File(args[1], "r") : stdin;
        foreach (line; f.byLine())
            writeln(ddemangle(line));
    }
    catch(Exception e)
    {
        stderr.writeln(e.msg);
        exit(1);
    }
}

// vim:set sw=4 ts=4 expandtab:
