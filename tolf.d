/* Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */

/* Replace line endings with LF
 */

import std.file;
import std.path;

int main(string[] args)
{
    foreach (f; args[1 .. $])
    {
        auto input = cast(char[]) std.file.read(f);
        auto output = filter(input);
        if (output != input)
            std.file.write(f, output);
    }
    return 0;
}


char[] filter(char[] input)
{
    char[] output;
    size_t j;

    for (size_t i = 0; i < input.length; i++)
    {
        auto c = input[i];

        switch (c)
        {
            case '\r':
                c = '\n';
                break;

            case '\n':
                if (i && input[i - 1] == '\r')
                    continue;
                break;

            case 0:
                continue;

            default:
                break;
        }
        output ~= c;
        j++;
    }
    return output[0 .. j];
}
