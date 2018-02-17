#!/usr/bin/env rdmd
/**
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(DMDSRC _checkwhitespace.d)
 */


import std.stdio;
import std.file;
import std.string;
import std.range;
import std.regex;
import std.algorithm;
import std.path;

int main(string[] args)
{
    import std.getopt;
    bool allowdos, allowtabs, allowtrailing;
    getopt(args,
           "allow-windows-newlines", &allowdos,
           "allow-tabs", &allowtabs,
           "allow-trailing-whitespace", &allowtrailing);

    bool error;
    auto r = regex(r" +\n");
    foreach(a; args[1..$])
    {
        try
        {
            ptrdiff_t pos;
            auto str = a.readText();
            if (!allowdos && (pos = str.indexOf("\r\n")) >= 0)
            {
                writefln("Error - file '%s' contains windows line endings at line %d", a, str[0..pos].count('\n') + 1);
                error = true;
            }
            if (!allowtabs && a.extension() != ".mak" && (pos = str.indexOf('\t')) >= 0)
            {
                writefln("Error - file '%s' contains tabs at line %d", a, str[0..pos].count('\n') + 1);
                error = true;
            }
            auto m = str.matchFirst(r);
            if (!allowtrailing && !m.empty)
            {
                pos = m.front.ptr - str.ptr; // assume the match is a slice of the string
                writefln("Error - file '%s' contains trailing whitespace at line %d", a, str[0..pos].count('\n') + 1);
                error = true;
            }
        }
        catch(Exception e)
        {
            writefln("Exception - file '%s': %s", a, e.msg);
        }
    }
    return error ? 1 : 0;
}
