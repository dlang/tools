
import std.stdio;
import std.file;
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

    foreach (line; File(args[1]).byLine(std.string.KeepTerminator.no, '<'))
    {
        if (!line.skipOver(`a name="`))
        {
            continue;
        }
        auto tag = findSplitBefore(line, `"`)[0];
        writefln("\"%s\",", tag);
    }

    writeln("]");

    return 0;
}

