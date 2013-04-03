#!/usr/bin/env rdmd

/* Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */

module catdoc;

import std.file;
import std.getopt;
import std.stdio;

int main(string[] args)
{
    if (args.length < 2)
    {
	writeln("catdoc: Concatenate Ddoc files
Usage:
    catdoc -o=outputfile sourcefiles...
");
	return 1;
    }

    string ofile;
    getopt(args, "o", &ofile);
    if (!ofile)
    {
	writeln("catdoc: set output file with -o=filename");
	return 1;
    }
    if (args.length < 2)
    {
	writeln("catdoc: no input files");
	return 1;
    }

    string comment = "Ddoc\n";
    string macros;
    foreach (arg; args[1..$])
    {
	//writeln(arg);
	string input = cast(string)std.file.read(arg);
	if (input.length < 4 || input[0..4] != "Ddoc")
	{   writefln("catdoc: %s is not a Ddoc file", arg);
	    return 1;
	}
	foreach (i, c; input)
	{
	    if (c == '\n')
	    {
		if (i + 8 < input.length && std.string.icmp(input[i + 1 .. i + 8], "Macros:") == 0)
		{
		    comment ~= input[4 .. i + 1];
		    if (!macros)
			macros = "Macros:\n";
		    macros ~= input[i + 8 .. $];
		    goto L1;
		}
	    }
	}
	comment ~= input[4 .. $];
    L1: ;
    }

    std.file.write(ofile, comment ~ macros);

    return 0;
}
