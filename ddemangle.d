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
        auto r = regex(r"\b(_D[0-9a-zA-Z_]+)\b");

        foreach (line; stdin.byLine())
        {
            writeln(replaceAll!(a => demangle(a.hit))(line, r));
        }
    }
    catch(Exception e)
    {
        stderr.writeln(e.msg);
        exit(1);
    }
}

// vim:set sw=4 ts=4 expandtab:
