// Written in the D programming language

/**
Change log generator which fetches the list of bugfixes
from the D Bugzilla between the given dates.
It stores its result in DDoc form to a text file.

Copyright: Dmitry Olshansky 2013.

License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).

Authors:   Dmitry Olshansky,
           Andrej Mitrovic

Example usage:
---
rdmd changed.d --start=2013-01-01 --end=2013-04-01
---
*/

// NOTE: this script requires libcurl to be linked in (usually done by default).

module changed;

import std.net.curl, std.conv, std.exception, std.algorithm, std.csv, std.typecons,
    std.stdio, std.datetime, std.array, std.string, std.file, std.format, std.getopt,
    std.path;

string[dchar] charToValid;
shared static this()
{
    charToValid = [':' : "_", ' ': ""];
}

/** Return a valid file name. */
string normalize(string input)
{
    return input.translate(charToValid);
}

/** Generate location for the cache file. */
string getCachePath(string start_date, string end_date)
{
    return buildPath(tempDir(),
                     format("dlog_%s_%s_%s_%s",
                            __DATE__, __TIME__, start_date, end_date).normalize());
}

auto templateRequest =
    `http://d.puremagic.com/issues/buglist.cgi?username=crap2crap%40yandex.ru&password=powerlow7&chfieldto={to}&query_format=advanced&chfield=resolution&chfieldfrom={from}&bug_status=RESOLVED&resolution=FIXED&product=D&ctype=csv&columnlist=component%2Cbug_severity%2Cshort_desc`;

auto generateRequest(string templ, Date start, Date end)
{
    auto ss = format("%04s-%02s-%02s", start.year, to!int(start.month), start.day);
    auto es = format("%04s-%02s-%02s", end.year, to!int(end.month), end.day);
    return templateRequest.replace("{from}", ss).replace("{to}", es);
}

auto dateFromStr(string sdate)
{
    int year, month, day;
    formattedRead(sdate, "%s-%s-%s", &year, &month, &day);
    return Date(year, month, day);
}

struct Entry
{
    int id;
    string summary;
}

string[dchar] parenToMacro;
shared static this()
{
    parenToMacro = ['(' : "$(LPAREN)", ')' : "$(RPAREN)"];
}

/** Replace '(' and ')' with macros to avoid closing down macros by accident. */
string escapeParens(string input)
{
    return input.translate(parenToMacro);
}

/** Generate and return the change log as a string. */
string getChangeLog(string start_date, string end_date)
{
    auto start = dateFromStr(start_date);
    auto end = end_date.empty ? to!Date(Clock.currTime()) : dateFromStr(end_date);
    auto req = generateRequest(templateRequest, start, end);
    debug stderr.writeln(req);  // write text
    auto data = req.get;

    // component (e.g. DMD) -> bug type (e.g. regression) -> list of bug entries
    Entry[][string][string] entries;

    immutable bugtypes = ["regressions", "bugs", "enhancements"];
    immutable components = ["DMD Compiler", "Phobos", "Druntime", "Optlink", "Installer", "Website"];

    foreach (fields; csvReader!(Tuple!(int, string, string, string))(data, null))
    {
        string comp = fields[1].toLower;
        switch (comp)
        {
            case "dmd": comp = "DMD Compiler"; break;
            case "websites": comp = "Website"; break;
            default: comp = comp.capitalize;
        }

        string type = fields[2].toLower;
        switch (type)
        {
            case "regression":
                type = "regressions";
                break;

            case "blocker", "critical", "major", "normal", "minor", "trivial":
                type = "bugs";
                break;

            case "enhancement":
                type = "enhancements";
                break;

            default: assert(0, type);
        }

        entries[comp][type] ~= Entry(fields[0], fields[3].idup);
    }

    Appender!string result;

    result ~= "$(BUGSTITLE Language Changes,\n";
    result ~= "-- Insert major language changes here --\n)\n\n";

    result ~= "$(BUGSTITLE Library Changes,\n";
    result ~= "-- Insert major library changes here --\n)\n\n";

    result ~= "$(BR)$(BIG List of all bug fixes and enhancements:)\n\n";

    foreach (component; components)
    if (auto comp = component in entries)
    {
        foreach (bugtype; bugtypes)
        if (auto bugs = bugtype in *comp)
        {
            result ~= format("$(BUGSTITLE %s %s,\n\n", component, bugtype);

            result ~= "$(P\n";
            foreach (bug; sort!"a.id < b.id"(*bugs))
            {
                result ~= format("$(LI $(BUGZILLA %s): %s)\n",
                              bug.id, bug.summary.escapeParens());
            }
            result ~= ")\n";
            result ~= ")\n";
        }
    }

    return result.data;
}

int main(string[] args)
{
    string start_date, end_date;
    bool ddoc = false;
    getopt(args,
        "start",  &start_date,    // numeric
        "end",    &end_date);     // string

    if (start_date.empty)
    {
        stderr.writefln("*ERROR: No start date set.\nUsage example:\n%s --start=YYYY-MM-HH [--end=YYYY-MM-HH] ",
               args[0].baseName);
        return 1;
    }

    // caching to avoid querying bugzilla
    // (depends on the compile date of the generator + the start and end dates)
    string cachePath = getCachePath(start_date, end_date);
    debug stderr.writefln("Cache file: %s\nCache file found: %s", cachePath, cachePath.exists);
    string changeLog;
    if (cachePath.exists)
    {
        changeLog = (cast(string)read(cachePath)).strip;
    }
    else
    {
        changeLog = getChangeLog(start_date, end_date);
        std.file.write(cachePath, changeLog);
    }

    string logPath = "./changelog.txt".absolutePath.buildNormalizedPath;
    std.file.write(logPath, changeLog);
    writefln("Change log generated to: '%s'", logPath);

    return 0;
}
