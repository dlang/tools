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
import core.demangle;

void main()
{
    foreach (line; stdin.byLine(File.KeepTerminator.yes))
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
                if (c == ' ' || c == '"' || c == '\'')
                {
                    endIdx = i;
                    state = State.done;
                }
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
}

