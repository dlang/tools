
import std.stdio;
import std.getopt;
import std.algorithm;
import std.regex;
import std.uri;

import std.process;

int main(string[] args)
{
    if (args.length < 2)
    {
        writeln("dman: Look up D topics in the manual
Usage:
    dman [--man] topic
");
        return 1;
    }

    bool man;
    getopt(args, "man", { man = true; });

    if (man)
    {   browse("http://www.digitalmars.com/ctg/dman.html");
        return 0;
    }
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
        url = Ddoc(topic);
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

string Ddoc(string topic)
{
    static string[] etags = mixin (import("expression.tag"));

    if (find(etags, topic).length)
    {
        return "http://www.d-programming-language.org/expression.html#" ~ topic;
    }

    static string[] stags = mixin (import("statement.tag"));

    if (find(stags, topic).length)
    {
        return "http://www.d-programming-language.org/statement.html#" ~ topic;
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
{   static string rtl = "http://www.digitalmars.com/rtl/";

    /******************** assert.h ***************************/

    if (topic == "assert")
        return rtl ~ "assert.html#assert";

    /**************** bios.h *******************************/

    static string[] biosfuncs =
    [
        "biosdisk",        "_bios_keybrd",        "biosprint",       "biostime",
        "_bios_disk",      "_bios_equiplist",     "_bios_memsize",   "_bios_printer",
        "_bios_serialcom", "_bios_timeofday",     "_int86",          "_int86x",
    ];

    switch (topic)
    {
        case "bioskey":         topic = "_bios_keybrd";    break;
        case "biosequip":       topic = "_bios_equiplist"; break;
        case "biosmemory":      topic = "_bios_memsize";   break;
        case "bioscom":         topic = "_bios_serialcom"; break;
        case "int86_real":
        case "int86":           topic = "_int86"; break;
        case "int86x_real":
        case "int86x":          topic = "_int86x"; break;
        default: break;
    }

    if (find(biosfuncs, topic).length)
        return rtl ~ "bios.html#" ~ topic;

    /**************** bitops.h *******************************/

    if (topic == "_inline_bsf" || topic == "_inline_bsr")
        return rtl ~ "bitops.html#" ~ topic;

    /**************** cerror.h *******************************/

    if (topic == "cerror_close" || topic == "cerror_open")
        return rtl ~ "cerror.html#" ~ topic;

    /******************** complex.h ***************************/

    /******************** conio.h ***************************/

    static string[] coniofuncs =
    [
        "_kbhit",  "_ungetch",
        "_getch",  "_getche",
        "_putch",  "_cgets",
        "_cprintf","_cputs",
        "_cscanf",
    ];

    if (find(coniofuncs, topic).length)
        return rtl ~ "conio.html#" ~ topic;

    /**************** controlc.h *******************************/

    if (topic == "controlc_close" || topic == "controlc_open")
        return rtl ~ "controlc.html#" ~ topic;

    /**************** ctype.h *******************************/

    static string[] isxxxxfuncs =
    [
        "isalnum",      "isalpha",      "__isascii",    "iscntrl",
        "__iscsym",     "__iscsymf",    "isdigit",      "isgraph",
        "islower",      "isprint",      "ispunct",      "isspace",
        "isupper",      "isxdigit",
    ];

    if (find(isxxxxfuncs, topic).length)
        return rtl ~ "ctype.html#isxxxx";

    static string[] toxxxxfuncs =
    [
        "_tolower", "tolower", "_toupper", "toupper",
    ];

    if (find(toxxxxfuncs, topic).length)
        return rtl ~ "ctype.html#_toxxxx";

    if (topic == "__toascii")
        return rtl ~ "ctype.html#__toascii";

    /******************** direct.h ***************************/

    static string[] directfuncs =
    [
        "_chdir",  "_chdrive", "_getcwd", "_getdrive",
        "_mkdir",  "_rmdir",   "fnmerge", "fnsplit",
        "searchpath",
    ];

    if (find(directfuncs, topic).length)
        return rtl ~ "direct.html#" ~ topic;

    /******************** disp.h ***************************/

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
        return rtl ~ "disp.html#" ~ topic;

    /******************** dos.h ***************************/

    static string[] dosfuncs =
    [
        "absread",                   "abswrite",
        "dos_abs_disk_read",         "dos_abs_disk_write",
        "dos_alloc",                  "_dos_allocmem",
        "dos_calloc",                 "_dos_close",
        "_dos_commit",                "dos_creat",
        "_dos_creat",                 "_dos_creatnew",
        "_doserrno",                  "_dosexterr",
        "_dos_findfirst",             "_dos_findnext",
        "dos_free",                   "_dos_freemem",
        "dos_get_ctrl_break",         "dos_get_verify",
        "_dos_getdate",               "_dos_getdiskfree",
        "dos_getdiskfreespace",       "_dos_getdrive",
        "_dos_getfileattr",           "_dos_getftime",
        "_dos_gettime",               "_dos_getvect",
        "_dos_keep",                  "_dos_lock",
        "_dos_open",                  "dos_open",
        "_dos_read",                  "_dos_seek",
        "_dos_setblock",              "dos_setblock",
        "dos_set_ctrl_break",         "_dos_setdate",
        "_dos_setdrive",              "_dos_setfileattr",
        "_dos_setftime",              "_dos_settime",
        "_dos_setvect",               "dos_set_verify",
        "_dos_write",                 "_x386_coreleft",
        "_x386_free_protected_ptr",   "_x386_get_abs_address",
        "_x386_map_physical_address", "_x386_memlock",
        "_x386_memunlock",            "_x386_mk_protected_ptr",
    ];

    switch (topic)
    {   case "_getdiskfree":
            topic = "_dos_getdiskfree";
            break;
        default:
            break;
    }

    if (find(dosfuncs, topic).length)
        return rtl ~ "dos.html#" ~ topic;

    /******************** dos2.h ***************************/

    static string[] dos2funcs =
    [
        "_bdos",        "_chain_intr",     "_disable",     "_enable",
        "_FP",          "_getdcwd",        "_hard",        "_inp",
        "_intdos",      "_intdosx",        "_MK_FP",       "_osversion",
        "_outp",        "_segread",        "allocmem",     "bdosptr",
        "bdosx",        "farcalloc",       "farcoreleft",  "farfree",
        "farmalloc",    "farrealloc",      "findfirst",    "findnext",
        "freemem",      "geninterrupt",    "getcbrk",      "getcurdir",
        "getdate",      "getdisk",         "getdta",       "getfat",
        "getfatd",      "getpsp",          "gettime",      "getverify",
        "parsfnm",      "peek",            "peekb",        "poke",
        "pokeb",        "response_expand", "setblock",     "setcbrk",
        "setdisk",      "setdta",          "setverify",
    ];

    switch (topic)
    {   case "_hardresume":
        case "_hardretn":
            topic = "_harderr";
            break;
        case "_inpw":
        case "_inpl":
            topic = "_inp";
            break;
        case "_outpw":
        case "_outpl":
            topic = "_outp";
            break;
        default:
            break;
    }

    if (find(dos2funcs, topic).length)
        return rtl ~ "dos2.html#" ~ topic;

    /******************** emm.h ***************************/

    static string[] emmfuncs =
    [
        "emm_allocpages",     "emm_deallocpages",   "emm_gethandlecount", "emm_gethandlespages",
        "emm_getpagemap",     "emm_getpagemapsize", "emm_getsetpagemap",  "emm_gettotal",
        "emm_getunalloc",     "emm_getversion",     "emm_init",           "emm_maphandle",
        "emm_physpage",       "emm_restorepagemap", "emm_savepagemap",    "emm_setpagemap",
        "emm_term",
    ];

    if (find(emmfuncs, topic).length)
        return rtl ~ "emm.html#" ~ topic;

    /******************** fenv.h ***************************/

    static string[] fenvfuncs =
    [
        "roundingmodes", "precisionmodes",  "feclearexcept",    "fegetexceptflag",
        "feraiseexcept", "fesetexceptflag", "fetestexcept",     "fegetprec",
        "fesetprec",     "fegetround",      "fesetround",       "fegetenv",
        "feholdexcept",  "fesetenv",        "feupdateenv",
    ];

    if (find(fenvfuncs, topic).length)
        return rtl ~ "fenv.html#" ~ topic;

    /******************** float.h ***************************/

    static string[] floatfuncs =
    [
        "_8087",        "_clear87",
        "_control87",   "_fpreset",
        "_status87",
    ];

    if (find(floatfuncs, topic).length)
        return rtl ~ "float.html#" ~ topic;

    /******************** fltpnt.h ***************************/

    static string[] fltpntfuncs =
    [
        "copysign",  "nearbyint", "nextafter", "remainder",
        "remquo",    "rint",      "rndtol",    "round",
        "scalb",     "trunc",
    ];

    if (find(fltpntfuncs, topic).length)
        return rtl ~ "fltpnt.html#" ~ topic;

    /******************** handle.h ***************************/

    static string[] handlefuncs =
    [
        "handle_calloc",   "handle_free",
        "handle_ishandle", "handle_malloc",
        "handle_realloc",  "handle_strdup",
    ];

    if (find(handlefuncs, topic).length)
        return rtl ~ "handle.html#" ~ topic;

    /******************** int.h ***************************/

    static string[] intfuncs =
    [
        "int_gen",       "int_getvector",
        "int_intercept", "int_on",
        "int_on",        "int_prev",
        "int_restore",   "int_setvector",
    ];

    if (find(intfuncs, topic).length)
        return rtl ~ "int.html#" ~ topic;

    /******************** io.h ***************************/

    static string[] iofuncs =
    [
        "_access",  "_chmod",      "_chsize",  "_close",
        "_commit",  "_creat",      "_dup",     "_dup2",
        "_eof",     "_filelength", "_isatty",  "_locking",
        "_lseek",   "_mktemp",     "_open",    "_read",
        "_setmode", "_sopen",      "_tell",    "_write",
        "_umask",   "_unlink",     "filesize", "getDS",
        "getftime", "lock",        "remove",   "rename",
        "setftime", "unlock",
    ];

    if (find(iofuncs, topic).length)
        return rtl ~ "io.html#" ~ topic;

    /******************** iostream ***************************/

    if (topic == "iostream")
        return rtl ~ "iostream.html";

    /******************** locale.h ***************************/

    if (topic == "localeconv" || topic == "setlocale")
        return rtl ~ "locale.html#" ~ topic;

    /******************** math.h ***************************/

    static string[] mathfuncs =
    [
        "fpclassify", "isfinite", "signbit",    "acos",
        "asin",       "atan",     "atan2",      "ceil",
        "cos",        "cosh",     "cbrt",       "exp",
        "exp2",       "expm1",    "fabs",       "floor",
        "fmod",       "frexp",    "hypot",      "ilogb",
        "ldexp",      "log",      "log2",       "logb",
        "log10",      "log1p",    "matherr",    "modf",
        "nextafter",  "poly",     "pow",        "sin",
        "sinh",       "sqrt",     "tan",        "tanh",
        "_cabs",
    ];

    switch (topic)
    {   case "isinf": case "isnan": case "isnormal":
            topic = "isinfinite";
            break;
        case "log1pf":
            topic = "log1p";
            break;
        case "_matherrl":
            topic = "matherr";
            break;
        default:
            break;
    }

    if (find(mathfuncs, topic).length)
        return rtl ~ "math.html#" ~ topic;

    /******************** msmouse.h ***************************/

    static string[] msmousefuncs =
    [
        "msm_condoff",      "msm_getpress", "msm_getrelease",   "msm_getstatus",
        "msm_hidecursor",   "msm_init",     "msm_lightpen",     "msm_lightpen",
        "msm_readcounters", "msm_setarea",  "msm_setarea",      "msm_setcurpos",
        "msm_setgraphcur",  "msm_setratio", "msm_settextcur",   "msm_setthreshhold",
        "msm_showcursor",   "msm_signal",   "msm_term",
    ];

    if (find(msmousefuncs, topic).length)
        return rtl ~ "msmouse.html#" ~ topic;

    /******************** new ***************************/

    if (topic == "_set_new_handler")
        return rtl ~ "new.html#_set_new_handler";

    /******************** oldcomplex.h ***************************/

    /******************** page.h ***************************/

    static string[] pagefuncs =
    [
        "page_calloc",     "page_free",
        "page_initialize", "page_malloc",
        "page_maxfree",    "page_realloc",
        "page_size",       "page_toptr",
    ];

    if (find(pagefuncs, topic).length)
        return rtl ~ "page.html#" ~ topic;

    /******************** process.h ***************************/

    static string[] processfuncs =
    [
        "_beginthread",  "_c_exit",
        "_exec",         "_endthread",
        "_getpid",       "_spawn",
    ];

    switch (topic)
    {   case "_cexit":
            topic = "_c_exit";
            break;
        case "_execl":
        case "_execle":
        case "_execlp":
        case "_execlpe":
        case "_execv":
        case "_execve":
        case "_execvp":
        case "_execvpe":
            topic = "_exec";
            break;
        case "_spawnl":
        case "_spawnle":
        case "_spawnlp":
        case "_spawnlpe":
        case "_spawnv":
        case "_spawnve":
        case "_spawnvp":
        case "_spawnvpe":
            topic = "_spawn";
            break;
        default:
            break;
    }

    if (find(processfuncs, topic).length)
        return rtl ~ "process.html#" ~ topic;

    /******************** regexp.h ***************************/

    /******************** search.h ***************************/

    if (topic == "_lfind" || topic == "_lsearch")
        return rtl ~ "search.html#" ~ topic;

    /******************** setjmp.h ***************************/

    if (topic == "setjmp" || topic == "longjmp")
        return rtl ~ "setjmp.html#" ~ topic;

    /******************** signal.h ***************************/

    if (topic == "raise" || topic == "signal")
        return rtl ~ "signal.html#" ~ topic;

    /******************** sound.h ***************************/

    if (topic == "sound_beep" || topic == "sound_click" || topic == "sound_tone")
        return rtl ~ "sound.html#" ~ topic;

    /******************** stdarg.h ***************************/

    if (topic == "va_arg" || topic == "va_end" || topic == "va_start")
        return rtl ~ "stdarg.html#va_arg";

    /******************** stddef.h ***************************/

    if (topic == "__threadid")
        return rtl ~ "stddef.html#_threadid";

    /******************** stdio.h ***************************/

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
        return rtl ~ "stdio.html#" ~ topic;

    /******************* stdlib.h ****************************/

    static string[] stdlibfuncs =
    [
        "__max",        "__min",        "_alloca",      "_atold",
        "_chkstack",    "_cpumode",     "_ecvt",        "_environ",
        "_exit",        "_fcvt",        "_fileinfo",    "_fmode",
        "_onexit",      "_freect",      "_fullpath",    "_gcvt",
        "_halloc",      "_hfree",       "_itoa",        "_lrotl",
        "_ltoa",        "_makepath",    "_memavl",      "_memmax",
        "_msize",       "_osmajor",     "_osminor",     "_osmode",
        "_osver",       "_pgmptr",      "_psp",         "_putenv",
        "_rotl",        "_searchenv",   "_splitpath",   "_stackavail",
        "_ultoa",       "_winmajor",    "_winminor",    "_winver",
        "exit",         "exit_pushstate", "abort",      "abs",
        "atexit",       "atof",         "atoi",         "atol",
        "bsearch",      "calloc",       "coreleft",     "errno",
        "expand",       "free",         "getenv",       "ldiv",
        "malloc",       "mblen",        "mbstowcs",     "mbtowc",
        "_memmax",      "perror",       "qsort",        "rand",
        "random",       "randomize",    "realloc",      "srand",
        "strtof",       "strtol",       "strtold",      "system",
        "_tolower",     "wcstombs",     "wctomb",
    ];

    switch (topic)
    {   case "_fmbstowcs":
        case "_fmbtowc":
        case "_fonexit":
        case "_fwcstombs":
        case "_fwctomb":
        case "_fatexit":
        case "_fmblen":
        case "_fcalloc":
        case "_ncalloc":
        case "_fmalloc":
        case "_nmalloc":
        case "_frealloc":
        case "_nrealloc":
        case "_fmsize":
        case "_nmsize":
            topic = topic[2..$];
            break;

        case "_lrotr":        topic = "_lrotl";  break;
        case "_rotr":         topic = "_rotl";   break;
        case "div":           topic = "ldiv";    break;
        case "exit_popstate": topic = "exit_pushstate"; break;
        case "strtod":        topic = "strtof"; break;
        case "strtoul":       topic = "strtol"; break;
        default:
            break;
    }

    if (find(stdlibfuncs, topic).length)
        return rtl ~ "stdlib.html#" ~ topic;

    /******************* string.h ****************************/

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
        return rtl ~ "string.html#" ~ topic;

    /******************** swap.h ***************************/

    static string[] swapfuncs =
    [
        "swap_clearkeyboard", "swap_freeparagraphs", "swap_freeparagraph", "swap_is",
        "swap_onoff",         "swap_pipe",           "swap_pipeonoff",     "swap_tempcheck",
        "swap_trapcbreak",    "swap_window",         "swap_windowonoff",
    ];

    switch (topic)
    {   case "swap_clearkeyboardoff":
        case "swap_clearkeyboardon":
            topic = "swap_clearkeyboard";
            break;
        case "swap_freeparagraphson":
        case "swap_freeparagraphsoff":
            topic = "swap_freeparagraph";
            break;
        case "swap_isclearkeyboardon":
        case "swap_isfreeparagraphson":
        case "swap_ison":
        case "swap_ispipeon":
        case "swap_istempcheckon":
        case "swap_istrapcbreakon":
        case "swap_iswindowon":
            topic = "swap_is";
            break;
        case "swap_on":
        case "swap_off":
            topic = "swap_onoff";
            break;
        case "swap_pipeon":
        case "swap_pipeoff":
            topic = "swap_pipeonoff";
            break;
        case "swap_tempcheckon":
        case "swap_tempcheckoff":
            topic = "swap_tempcheck";
            break;
        case "swap_trapcbreakon":
        case "swap_trapcbreakoff":
            topic = "swap_trapcbreak";
            break;
        case "swap_windowon":
        case "swap_windowoff":
            topic = "swap_windowonoff";
            break;
        default:
            break;
    }

    if (find(swapfuncs, topic).length)
        return rtl ~ "swap.html#" ~ topic;

    /******************** sys-stat.h ***************************/

    if (topic == "_fstat" || topic == "_stat")
        return rtl ~ "sys-stat.html#" ~ topic;

    /******************** tabsize.h ***************************/

    if (topic == "tab_sizeget" || topic == "tab_sizegetenv" ||
        topic == "tab_sizeputenv" || topic == "tab_sizeset")
        return rtl ~ "tabsize.html#" ~ topic;

    /******************** time.h ***************************/

    static string[] timefuncs =
    [
        "_daylight", "difftime", "_ftime",    "_strdate",
        "_timezone", "_tzname",  "_tzset",    "_utime",
        "asctime",   "clock",    "ctime",     "gmtime",
        "localtime", "mktime",   "msleep",    "sleep",
        "strftime",  "time",     "usleep",
    ];

    if (find(timefuncs, topic).length)
        return rtl ~ "time.html#" ~ topic;

    /******************** tsr.h ***************************/

    if (topic == "tsr_install" || topic == "tsr_service" ||
        topic == "tsr_uninstall")
        return rtl ~ "tsr.html#" ~ topic;

    /******************** unmangle.h ***************************/

    if (topic == "unmangle_ident")
        return rtl ~ "unmangle.html#unmangle_ident";

    /******************** util.h ***************************/

    if (topic == "file_append" || topic == "file_read" ||
        topic == "file_write")
        return rtl ~ "util.html#" ~ topic;

    /******************** winio.h ***************************/

    static string[] winiofuncs =
    [
        "ungets",             "winio_about",       "winio_bufsize",      "winio_clear",
        "winio_close",        "winio_closeall",    "winio_current",      "winio_defwindowsize",
        "winio_end",          "winio_getinfo",     "winio_hmenufile",    "winio_hmenuhelp",
        "winio_hmenumain",    "winio_home",        "winio_init",         "winio_onclose",
        "winio_onpaintentry", "winio_onpaintexit", "winio_openwindows",  "winio_resetbusy",
        "winio_setbufsize",   "winio_setbusy",     "winio_setcurrent",   "winio_setecho",
        "winio_setfont",      "winio_setlinefn",   "winio_setmenufunc",  "winio_setpaint",
        "winio_settitle",     "winio_warn",        "winio_window",       "wmhandler_create",
        "wmhandler_destroy",  "wmhandler_get",     "wmhandler_hwnd",     "wmhandler_set",
    ];

    if (find(winiofuncs, topic).length)
        return rtl ~ "winio.html#" ~ topic;

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
