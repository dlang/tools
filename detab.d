
/* Replace tabs with spaces, and remove trailing whitespace from lines.
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

    int column;
    for (size_t i = 0; i < input.length; i++)
    {
        auto c = input[i];

        switch (c)
        {
            case '\t':
                while ((column & 7) != 7)
                {   output ~= ' ';
                    j++;
                    column++;
                }
                c = ' ';
                column++;
                break;

            case '\r':
            case '\n':
                while (j && output[j - 1] == ' ')
                    j--;
                output = output[0 .. j];
                column = 0;
                break;

            default:
                column++;
                break;
        }
        output ~= c;
        j++;
    }
    while (j && output[j - 1] == ' ')
        j--;
    return output[0 .. j];
}
