#!/usr/bin/env rdmd
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
rdmd changed.d --start=2013-01-01 (end date implicitly set to current date)
---

$(B Note:) The script will cache the results of an invocation, to avoid
re-querying bugzilla when invoked with the same arguments.
Use the --nocache option to override this behavior.
*/

// NOTE: this script requires libcurl to be linked in (usually done by default).

module changed;

import std.net.curl, std.conv, std.exception, std.algorithm, std.csv, std.typecons,
    std.stdio, std.datetime, std.array, std.string, std.file, std.format, std.getopt,
    std.path;

auto templateRequest =
    `https://issues.dlang.org/buglist.cgi?bug_id={buglist}&bug_status=RESOLVED&resolution=FIXED&`~
        `ctype=csv&columnlist=component,bug_severity,short_desc`;

auto generateRequest(Range)(string templ, Range issues)
{
    auto buglist = format("%(%d,%)", issues);
    return templateRequest.replace("{buglist}", buglist);
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

/** Get a list of all bugzilla issues mentioned in revRange */
auto getIssues(string revRange)
{
    import std.process : pipeProcess, Redirect, wait;
    import std.regex : ctRegex, match, splitter;

    // see https://github.com/github/github-services/blob/2e886f407696261bd5adfc99b16d36d5e7b50241/lib/services/bugzilla.rb#L155
    enum closedRE = ctRegex!(`((close|fix|address)e?(s|d)? )?(ticket|bug|tracker item|issue)s?:? *([\d ,\+&#and]+)`, "i");

    auto issues = appender!(int[]);
    foreach (repo; ["dmd", "druntime", "phobos", "dlang.org", "tools", "installer"]
             .map!(r => buildPath("..", r)))
    {
        auto cmd = ["git", "-C", repo, "fetch", "upstream", "--tags"];
        auto p = pipeProcess(cmd, Redirect.stdout);
        enforce(wait(p.pid) == 0, "Failed to execute '%(%s %)'.".format(cmd));

        cmd = ["git", "-C", repo, "log", revRange];
        p = pipeProcess(cmd, Redirect.stdout);
        scope(exit) enforce(wait(p.pid) == 0, "Failed to execute '%(%s %)'.".format(cmd));

        foreach (line; p.stdout.byLine())
        {
            if (auto m = match(line, closedRE))
            {
                if (!m.captures[1].length) continue;
                m.captures[5]
                    .splitter(ctRegex!`[^\d]+`)
                    .filter!(b => b.length)
                    .map!(to!int)
                    .copy(issues);
            }
        }
    }
    return issues.data.sort().release.uniq;
}

/** Generate and return the change log as a string. */
string getChangeLog(string revRange)
{
    auto req = generateRequest(templateRequest, getIssues(revRange));
    debug stderr.writeln(req);  // write text
    auto data = req.get;

    // component (e.g. DMD) -> bug type (e.g. regression) -> list of bug entries
    Entry[][string][string] entries;

    immutable bugtypes = ["regressions", "bugs", "enhancements"];
    immutable components = ["DMD Compiler", "Phobos", "Druntime", "dlang.org", "Optlink", "Tools", "Installer"];

    foreach (fields; csvReader!(Tuple!(int, string, string, string))(data, null))
    {
        string comp = fields[1].toLower;
        switch (comp)
        {
            case "dlang.org": comp = "dlang.org"; break;
            case "dmd": comp = "DMD Compiler"; break;
            case "druntime": comp = "Druntime"; break;
            case "installer": comp = "Installer"; break;
            case "phobos": comp = "Phobos"; break;
            case "tools": comp = "Tools"; break;
            default: assert(0, comp);
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
            foreach (bug; sort!"a.id < b.id"(*bugs))
            {
                result ~= format("$(LI $(BUGZILLA %s): %s)\n",
                              bug.id, bug.summary.escapeParens());
            }
            result ~= ")\n";
        }
    }

    return result.data;
}

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writeln("Usage: ./changed <revision range>, e.g. ./changed v2.067.1..upstream/stable");
        return 1;
    }

    string logPath = "./changelog.txt".absolutePath.buildNormalizedPath;
    std.file.write(logPath, getChangeLog(args[1]));
    writefln("Change log generated to: '%s'", logPath);

    return 0;
}
