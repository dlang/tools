#!/usr/bin/env rdmd
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
import core.stdc.stdlib;

void showhelp(string[] args)
{
    stderr.writef(q"ENDHELP
Usage: %s [options] [<inputfile>]
Demangles all occurrences of mangled D symbols in the input and writes to
standard output.
If <inputfile> is omitted, standard input is read.
Options:
    --help, -h                  Show this help
    --underscore_missing, -u    handling missing underscore (eg with lldb on OSX)
ENDHELP", args[0]);

    exit(1);
}

enum suffix = r"D[0-9a-zA-Z_]+\b";
auto reDemangle = regex(r"\b_?_" ~ suffix);
auto reDemangle_underscore_missing = regex(r"\b" ~ suffix);

const(char)[] demangleMatch(T)(Captures!(T) m) if (is(T : const(char)[]))
{
    /+ If the second character is an underscore, it may be a D symbol with double leading underscore;
     + in that case, try to demangle it with only one leading underscore.
     +/
    if (m.hit[1] != '_')
    {
        return demangle(m.hit);
    }
    else
    {
        auto result = demangle(m.hit[1 .. $]);
        if (result == m.hit[1 .. $])
        {
            // Demangling failed, return original match with (!) double underscore
            return m.hit;
        }
        else
        {
            return result;
        }
    }
}

const(char)[] demangleMatchUnderscoreMissing(T)(Captures!(T) m)
        if (is(T : const(char)[]))
{
    static Appender!string ret;
    ret.ret;
    ret ~= "_";
    ret ~= m.hit;
    auto line2 = ret.data;
    auto result = demangle(line2);
    if (result == line2)
    {
        // Demangling failed, return original match
        return m.hit;
    }
    else
    {
        return result;
    }
}

auto ddemangle(T)(T line, bool underscore_missing) if (is(T : const(char)[]))
{
    if (underscore_missing)
        return replaceAll!demangleMatch(line, reDemangle_underscore_missing);
    else
        return replaceAll!demangleMatch(line, reDemangle);
}

unittest
{
    string[] testData = [
        "_D2rt4util7console8__assertFiZv",
        "random initial junk _D2rt4util7console8__assertFiZv random trailer",
        "multiple _D2rt4util7console8__assertFiZv occurrences _D2rt4util7console8__assertFiZv",
        "_D6object9Throwable8toStringMFZAya",
        "__D6object9Throwable8toStringMFZAya",
        "don't match 3 leading underscores ___D6object9Throwable8toStringMFZAya",
        "fail demangling __D6object9Throwable8toStringMFZAy"
    ];
    string[] expected = [
        "void rt.util.console.__assert(int)",
        "random initial junk void rt.util.console.__assert(int) random trailer",
        "multiple void rt.util.console.__assert(int) occurrences void rt.util.console.__assert(int)",
        "immutable(char)[] object.Throwable.toString()",
        "immutable(char)[] object.Throwable.toString()",
        "don't match 3 leading underscores ___D6object9Throwable8toStringMFZAya",
        "fail demangling __D6object9Throwable8toStringMFZAy"
    ];

    assert(equal(testData.map!ddemangle(), expected));
}

void main(string[] args)
{
    bool underscore_missing = false;
    // Parse command-line arguments
    try
    {
        getopt(args, "help|h", { showhelp(args); }, "underscore_missing|u", {
            underscore_missing = true;
        },);
        if (args.length > 2)
            showhelp(args);
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg);
        stderr.writeln();
        showhelp(args);
    }

    // Process input
    try
    {
        auto f = (args.length == 2) ? File(args[1], "r") : stdin;
        foreach (line; f.byLine())
        {
            writeln(ddemangle(line, underscore_missing));
            stdout.flush;
        }
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg);
        exit(1);
    }
}

// vim:set sw=4 ts=4 expandtab:
