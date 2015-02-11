#!/usr/bin/env rdmd

/* Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */

module reindent;

import std.range.primitives;

/**
 * Reindents an input range of lines.
 *
 * Each line is assumed to consist of an initial run of spaces that are n
 * multiples of inputIndent. The output lines are constructed by substituting
 * this initial run of spaces with n multiples of outputIndent instead.
 *
 * The primary usage is intended to be for reindenting space-indented code.
 *
 * Note that the input is assumed to be already properly-indented. This
 * function does not attempt to parse or pretty-print the input.
 *
 * Params:
 *  range = Input range of lines to be reindented.
 *  inputIndent = The number of spaces to be counted as a single level of
 *      indentation in the input.
 *  outputIndent = The number of spaces per indentation level to be used in the
 *      output.
 *
 * Returns: An input range of lines.
 */
auto reIndent(R)(R range, size_t inputIndent, size_t outputIndent)
    if (isInputRange!R && is(ElementType!R : const(char)[]))
{
    import std.algorithm.iteration : map;
    import std.array;
    import std.regex;

    auto reSplitInitialSpace = regex(`^( +)(.*)`, "s");
    auto reReindent = regex(" ".replicate(inputIndent));
    string outIndent = " ".replicate(outputIndent);

    return range.map!((line) {
        auto m = line.match(reSplitInitialSpace);
        if (m)
        {
            auto newIndent = m.captures[1].replaceAll(reReindent, outIndent);
            return newIndent ~ m.captures[2];
        }
        else
            return line;
    });
}

unittest
{
    auto r = [
        "void main(string[] args)\n",
        "{\n",
        "    if (args.length == 1)\n",
        "    {\n",
        "        writeln(\"Exactly one argument\n\");\n",
        "    }\n",
        "    else\n",
        "    {\n",
        "        foreach (arg; args)\n",
        "        {\n",
        "            writeln(arg);\n",
        "        }\n",
        "    }\n",
        "}\n",
    ].reIndent(4, 2);

    import std.algorithm.comparison : equal;
    assert(r.equal([
        "void main(string[] args)\n",
        "{\n",
        "  if (args.length == 1)\n",
        "  {\n",
        "    writeln(\"Exactly one argument\n\");\n",
        "  }\n",
        "  else\n",
        "  {\n",
        "    foreach (arg; args)\n",
        "    {\n",
        "      writeln(arg);\n",
        "    }\n",
        "  }\n",
        "}\n",
    ]));
}

/**
 * Prints out program usage.
 */
void help(string progName)
{
    import std.stdio;

    writef(q"END
Usage: %s [options]
Options:
  -i<n>   Specify spaces per indentation level in input [Default: 4]
  -o<n>   Specify spaces per indentation level in output [Default: 2]
END",
        progName);

    import core.stdc.stdlib;
    exit(1);
}

/// Main program.
void main(string[] args)
{
    size_t inputIndent = 4;
    size_t outputIndent = 2;

    import std.getopt;

    getopt(args,
           "h", { help(args[0]); },
           "i", &inputIndent,
           "o", &outputIndent);

    import std.algorithm.iteration : map;
    import std.algorithm.mutation : copy;
    import std.stdio;

    stdin.byLine(KeepTerminator.yes)
         .reIndent(inputIndent, outputIndent)
         .copy(stdout.lockingTextWriter());
}
