/* Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */

import std.stdio;
import std.file;
import std.string;
import std.algorithm;

int main(string[] args)
{
    if (args.length != 2)
    {
        writeln("findtags: Find link tags in html file
Usage:
    findtags htmlfile
");
        return 1;
    }

    string ifile = args[1];

    writeln("[");

    foreach (line; File(ifile).byLine(std.string.KeepTerminator.no, '<'))
    {
        if (!line.skipOver(`a name="`))
        {
            continue;
        }
        auto tag = findSplitBefore(line, `"`)[0];
        writefln(`"%s",`, tag);
    }

    writeln("]");

    return 0;
}

