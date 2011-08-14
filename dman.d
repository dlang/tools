
import std.stdio;
import std.getopt;
import std.algorithm;
import std.regex;
import std.uri;

import std.net.browser;

int main(string[] args)
{
    if (args.length < 2)
    {
        writeln("dman: Look up D topics in the manual
Usage:
    dman [-man] topic
");
        return 1;
    }

    bool man;
    getopt(args, "man", { man = true; });

    if (man)
        browse("http://www.digitalmars.com/");
    else if (args.length != 2)
    {
        writeln("dman: no topic");
        return 1;
    }

    auto topic = args[1];

    auto url = topic2url(topic);
    if (url)
    {
        browse(url);
    }
    else
    {
        writefln("dman: topic '%s' not found", topic);
        return 1;
    }

    return 0;
}

string topic2url(string topic)
{
    /* Instead of hardwiring these, dman should read from a .json database pointed to
     * by sc.ini or dmd.conf.
     */

    string url;

    url = DmcCommands(topic);
    if (!url)
        url = CHeader(topic);
    if (!url)
        url = Clib(topic);
    if (!url)
        url = Misc(topic);
    if (!url)
        url = Phobos(topic);
    if (!url)
        // Try "I'm Feeling Lucky"
        url = "http://www.google.com/search?q=" ~
              std.uri.encode(topic) ~
              "&as_oq=site:d-programming-language.org+site:digitalmars.com&btnI=I%27m+Feeling+Lucky";
    return url;
}

string DmcCommands(string topic)
{
    static string[] dmccmds =
    [ "bcc", "chmod", "cl", "coff2omf", "coffimplib", "dmc", "diff", "diffdir",
      "dman",
      "dump", "dumpobj", "dumpexe", "exe2bin", "flpyimg", "grep", "hc", "htod",
      "implib", "lib", "libunres", "link", "linker", "make", "makedep",
      "me", "obj2asm", "optlink", "patchobj",
      "rc", "rcc", "sc", "shell", "smake", "touch", "unmangle", "whereis",
    ];

    if (find(dmccmds, topic).length)
    {
        if (topic == "dmc")
            topic = "sc";
        else if (topic == "link")
            topic = "optlink";
        else if (topic == "linker")
            topic = "optlink";
        return "http://www.digitalmars.com/ctg/" ~ topic ~ ".html";
    }
    return null;
}

string CHeader(string topic)
{
    static string[] dmccmds =
    [
        "assert.h",     "complex.h",   "ctype.h",      "fenv.h",
        "float.h",      "locale.h",    "math.h",       "setjmp.h,"
        "signal.h",     "stdarg.h",    "stddef.h",     "stdio.h",
        "stdlib.h",     "string.h",    "time.h",       "gc.h",
        "bios.h",       "cerror.h",    "disp.h",       "dos.h",
        "emm.h",        "handle.h",    "int.h",        "msmouse.h",
        "sound.h",      "swap.h",      "tsr.h",        "winio.h",
        "bitops.h",     "conio.h",     "controlc.h",   "direct.h",
        "fltpnt.h",     "io.h",        "page.h",       "process.h",
        "search.h",     "sys/stat.h",  "tabsize.h",    "trace.h",
        "utime.h",      "unmangle.h",  "util.h",       "regexp.h",
        "complex.h",    "iostream.h",
    ];

    if (find(dmccmds, topic).length)
    {
        return "http://www.digitalmars.com/rtl/" ~ topic ~ "tml";
    }
    return null;
}

string Clib(string topic)
{
    /***********************************************/

    static string[] isxxxxfuncs =
    [
        "isalnum",      "isalpha",      "__isascii",    "iscntrl",
        "__iscsym",     "__iscsymf",    "isdigit",      "isgraph",
        "islower",      "isprint",      "ispunct",      "isspace",
        "isupper",      "isxdigit",
    ];

    if (find(isxxxxfuncs, topic).length)
        return "http://www.digitalmars.com/rtl/ctype.html#isxxxx";

    static string[] toxxxxfuncs =
    [
        "_tolower", "tolower", "_toupper", "toupper",
    ];

    if (find(toxxxxfuncs, topic).length)
        return "http://www.digitalmars.com/rtl/ctype.html#_toxxxx";

    if (topic == "__toascii")
        return "http://www.digitalmars.com/rtl/ctype.html#__toascii";

    /***********************************************/

    static string[] dispfuncs =
    [
        "disp_box",     "disp_close",   "disp_eeol",    "disp_eeop",
        "disp_endstand", "disp_fillbox", "disp_flush",  "disp_getattr",
        "disp_getmode", "disp_hidecursor", "disp_move", "disp_open",
        "disp_peekbox", "disp_peekw",   "disp_pokebox", "disp_pokew",
        "disp_printf",  "disp_putc",    "disp_puts",    "disp_reset43",
        "disp_scroll",  "disp_set43",   "disp_setattr", "disp_setcursortype",
        "disp_setmode", "disp_showcursor", "disp_startstand", "disp_usebios",
    ];

    if (find(dispfuncs, topic).length)
        return "http://www.digitalmars.com/rtl/disp.html#" ~ topic;

    /***********************************************/

    static string[] stdiofuncs =
    [
        "_fcloseall",  "_fdopen",     "_fgetchar",   "_fileno",
        "_flushall",   "_fputchar",   "_fsopen",     "_getw",
        "_okbigbuf",   "_putw",       "_rmtmp",      "_stdaux",
        "_stdprn",     "_tempnam",    "clearerr",    "fclose",
        "feof",        "ferror",      "fflush",      "fgetc",
        "fgetpos",     "fgets",       "fopen",       "printf",
        "fputc",       "fputs",       "fread",       "freopen",
        "scanf",       "fseek",       "fsetpos",     "ftell",
        "fwrite",      "getc",        "getchar",     "gets",
        "putc",        "putchar",     "puts",        "rewind",
        "setbuf",      "setvbuf",     "stderr",      "stdin",
        "stdout",      "tmpfile",     "tmpnam",      "ungetc",
        "vprintf",
    ];

    switch (topic)
    {   case "fprintf":
        case "sprintf":
        case "_snprintf":
            topic = "printf";
            break;
        case "fscanf":
        case "sscanf":
            topic = "scanf";
            break;
        default:
            break;
    }

    if (find(stdiofuncs, topic).length)
        return "http://www.digitalmars.com/rtl/stdio.html#" ~ topic;

    /***********************************************/

    static string[] stringfuncs =
    [
        "memchr",       "memcmp",      "_memccpy",     "memcpy",
        "_memicmp",     "memmove",     "memset",       "_movedata",
        "movmem",       "_strdup",     "_stricmp",     "_strlwr",
        "strncmpi",     "_strnset",    "_strrev",      "_strset",
        "_strtime",     "_strupr",     "_swab",        "stpcpy",
        "strcat",       "strchr",      "strcmp",       "strcoll",
        "strcpy",       "strcspn",     "strerror",     "strlen",
        "strncat",      "strncmp",     "strncmpi",     "strncpy",
        "strpbrk",      "strrchr",     "strspn",       "strstr",
        "strtok",       "strxfrm",     "_sys_errlist", "_sys_nerr",
    ];

    switch (topic)
    {
        case "_fmemccpy":   topic = "_memccpy"; break;
        case "_fmemicmp":   topic = "_memicmp"; break;
        case "_fmemmove":   topic = "_memmove"; break;
        case "setmem":
        case "_fmemset":    topic = "memset"; break;
        case "_fstrdup":    topic = "_strdup"; break;
        case "_fstricmp":   topic = "_stricmp"; break;
        case "_fstrlwr":    topic = "_strlwr"; break;
        case "_strnicmp":
        case "_fstrnicmp":
        case "strncmpl":   topic = "strncmpi"; break;
        case "_fstrnset":   topic = "_strnset"; break;
        case "_fstrrev":   topic = "_strrev"; break;
        case "_fstrset":   topic = "_strset"; break;
        case "_fstrupr":   topic = "_strupr"; break;

        case "_fmemchr":
        case "_fmemcmp":
        case "_fmemcpy":
        case "_fstrcat":
        case "_fstrchr":
        case "_fstrcpy":
        case "_fstrcspn":
        case "_fstrlen":
        case "_fstrncat":
        case "_fstrncmp":
        case "_fstrncpy":
        case "_fstrpbrk":
        case "_fstrrchr":
        case "_fstrspn":
        case "_fstrstr":
        case "_fstrtok":   topic = topic[2..$]; break;
        default:
            break;
    }

    if (find(stringfuncs, topic).length)
        return "http://www.digitalmars.com/rtl/string.html#" ~ topic;

    /***********************************************/

    return null;
}

string Misc(string topic)
{
    string[string] misc =
    [
        "D1": "http://www.digitalmars.com/d/1.0/",
        "D2": "http://www.d-programming-language.org/",
        "faq": "http://d-programming-language.org/faq.html",
    ];

    auto purl = topic in misc;
    if (purl)
        return *purl;
    return null;
}

string Phobos(string topic)
{
    string phobos = "http://www.d-programming-language.org/phobos/";
    if (find(topic, '.').length)
    {
        topic = replace(topic, regex("\\.", "g"), "_");
        return phobos ~ topic ~ ".html";
    }
    return null;
}
