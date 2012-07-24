/**
 * Demangler filter for D symbols: demangle the first D mangled symbol
 * found on each line (if any) from standard input and send the
 * result to standard output.
 *
 * Copyright:  2011 Michel Fortin
 * License:    <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Author:     Michel Fortin
 */
/*              Copyright Michel Fortin 2011.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module ddemangle;

import std.stdio;
import std.ascii;
import core.demangle;

int main(string[] args)
{
    if (args.length != 1)
    {    // this takes care of the --help / -h case too!
        stderr.writeln("Usage: ", args[0], " [-h|--help]");
        stderr.writeln("Demangler filter for D symbols: demangle the first D mangled symbol
found on each line (if any) from standard input and send the result
to standard output.");
        if (args.length != 2 || (args[1] != "--help" && args[1] != "-h"))
            return 1; // invalid arguments
        return 0; // help called normally
    }

    foreach (line; stdin.byLine(KeepTerminator.yes))
    {
        size_t beginIdx, endIdx;

        enum State { searching_, searchingD, searchingEnd, done }
        State state;
        foreach (i, char c; line)
        {
            switch (state)
            {
            case State.searching_:
                if (c == '_')
                {
                    beginIdx = i;
                    state = State.searchingD;
                }
                break;
            case State.searchingD:
                if (c == 'D')
                    state = State.searchingEnd;
                else if (c != '_')
                    state = State.searching_;
                break;
            case State.searchingEnd:
                if (!isAlphaNum(c) && c != '_')
                {
                    endIdx = i;
                    state = State.done;
                }
                break;
            default:
                break;
            }
            if (state == State.done)
                break;
        }

        if (endIdx > beginIdx)
            write(line[0..beginIdx], demangle(line[beginIdx..endIdx]), line[endIdx..$]);
        else
            write(line);
    }
    return 0;
}

