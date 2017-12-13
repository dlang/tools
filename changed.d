#!/usr/bin/env rdmd

// Written in the D programming language

/**
Change log generator which fetches the list of bugfixes
from the D Bugzilla between the given dates.
Moreover manual changes are accumulated from raw text files in the
Dlang repositories.
It stores its result in DDoc form to a text file.

Copyright: D Language Foundation 2016.

License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).

Authors:   Dmitry Olshansky,
           Andrej Mitrovic,
           Sebastian Wilzbach

Example usage:

---
rdmd changed.d "v2.071.2..upstream/stable"
---

It is also possible to directly preview the generated changelog file:

---
rdmd changed.d "v2.071.2..upstream/stable" && dmd ../dlang.org/macros.ddoc ../dlang.org/html.ddoc ../dlang.org/dlang.org.ddoc ../dlang.org/doc.ddoc ../dlang.org/changelog/changelog.ddoc changelog.dd -Df../dlang.org/web/changelog/pending.html
---

If no arguments are passed, only the manual changes will be accumulated and Bugzilla
won't be queried (faster).

A manual changelog entry consists of a title line, a blank separator line and
the description.
*/

// NOTE: this script requires libcurl to be linked in (usually done by default).

module changed;

import std.net.curl, std.conv, std.exception, std.algorithm, std.csv, std.typecons,
    std.stdio, std.datetime, std.array, std.string, std.file, std.format, std.getopt,
    std.path;

import std.range.primitives, std.traits;

struct BugzillaEntry
{
    int id;
    string summary;
}

struct ChangelogEntry
{
    string title; // the first line (can't contain links)
    string description; // a detailed description (separated by a new line)
    string basename; // basename without extension (used for the anchor link to the description)
}

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
    import std.process : execute, pipeProcess, Redirect, wait;
    import std.regex : ctRegex, match, splitter;

    // see https://github.com/github/github-services/blob/2e886f407696261bd5adfc99b16d36d5e7b50241/lib/services/bugzilla.rb#L155
    enum closedRE = ctRegex!(`((close|fix|address)e?(s|d)? )?(ticket|bug|tracker item|issue)s?:? *([\d ,\+&#and]+)`, "i");

    auto issues = appender!(int[]);
    foreach (repo; ["dmd", "druntime", "phobos", "dlang.org", "tools", "installer"]
             .map!(r => buildPath("..", r)))
    {
        auto cmd = ["git", "-C", repo, "fetch", "--tags", "https://github.com/dlang/" ~ repo.baseName,
                           "+refs/heads/*:refs/remotes/upstream/*"];
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
auto getBugzillaChanges(string revRange)
{
    // component (e.g. DMD) -> bug type (e.g. regression) -> list of bug entries
    BugzillaEntry[][string][string] entries;

    auto issues = getIssues(revRange);
    // abort prematurely if no issues are found in all git logs
    if (issues.empty)
        return entries;

    auto req = generateRequest(templateRequest, issues);
    debug stderr.writeln(req);  // write text
    auto data = req.get;

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
            case "visuald": comp = "VisualD"; break;
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

        entries[comp][type] ~= BugzillaEntry(fields[0], fields[3].idup);
    }
    return entries;
}

/**
Reads a single changelog file.

An entry consists of a title line, a blank separator line and
the description

Params:
    filename = changelog file to be parsed

Returns: The parsed `ChangelogEntry`
*/
ChangelogEntry readChangelog(string filename)
{
    import std.algorithm.searching : countUntil;
    import std.file : read;
    import std.path : baseName, stripExtension;
    import std.string : strip;

    auto lines = filename.readText().splitLines();

    // filter empty files
    if (lines.empty)
        return ChangelogEntry.init;

    // filter ddoc files
    if (lines[0].startsWith("Ddoc"))
        return ChangelogEntry.init;

    enforce(lines.length >= 3 &&
        !lines[0].empty &&
         lines[1].empty &&
        !lines[2].empty,
        "Changelog entries should consist of one title line, a blank separator line, and a description.");

    ChangelogEntry entry = {
        title: lines[0].strip,
        description: lines[2..$].join("\n").strip,
        basename: filename.baseName.stripExtension
    };
    return entry;
}

/**
Looks for changelog files (ending with `.dd`) in a directory and parses them.

Params:
    changelogDir = directory to search for changelog files

Returns: An InputRange of `ChangelogEntry`s
*/
auto readTextChanges(string changelogDir)
{
    import std.algorithm.iteration : filter, map;
    import std.file : dirEntries, SpanMode;
    import std.string : endsWith;

    return dirEntries(changelogDir, SpanMode.shallow)
            .filter!(a => a.name().endsWith(".dd"))
            .array.sort()
            .map!readChangelog
            .filter!(a => a.title.length > 0);
}

/**
Writes the overview headline of the manually listed changes in the ddoc format as list.

Params:
    changes = parsed InputRange of changelog information
    w = Output range to use
*/
void writeTextChangesHeader(Entries, Writer)(Entries changes, Writer w, string headline)
    if (isInputRange!Entries && isOutputRange!(Writer, string))
{
    // write the overview titles
    w.formattedWrite("$(BUGSTITLE_TEXT_HEADER %s,\n\n", headline);
    scope(exit) w.put("\n)\n\n");
    foreach(change; changes)
    {
        w.formattedWrite("$(LI $(RELATIVE_LINK2 %s,%s))\n", change.basename, change.title);
    }
}
/**
Writes the long description of the manually listed changes in the ddoc format as list.

Params:
    changes = parsed InputRange of changelog information
    w = Output range to use
*/
void writeTextChangesBody(Entries, Writer)(Entries changes, Writer w, string headline)
    if (isInputRange!Entries && isOutputRange!(Writer, string))
{
    w.formattedWrite("$(BUGSTITLE_TEXT_BODY %s,\n\n", headline);
    scope(exit) w.put("\n)\n\n");
    foreach(change; changes)
    {
        w.formattedWrite("$(LI $(LNAME2 %s,%s)\n", change.basename, change.title);
        scope(exit) w.put(")\n\n");

        bool inPara, inCode;
        foreach (line; change.description.splitLines)
        {
            if (line.startsWith("---"))
            {
                if (inPara)
                {
                    w.put(")\n");
                    inPara = false;
                }
                inCode = !inCode;
            }
            else if (!inCode && !inPara && !line.empty)
            {
                w.put("$(P\n");
                inPara = true;
            }
            else if (inPara && line.empty)
            {
                w.put(")\n");
                inPara = false;
            }
            w.put(line);
            w.put("\n");
        }
        if (inPara)
            w.put(")\n");
    }
}

/**
Writes the fixed issued from Bugzilla in the ddoc format as a single list.

Params:
    changes = parsed InputRange of changelog information
    w = Output range to use
*/
void writeBugzillaChanges(Entries, Writer)(Entries entries, Writer w)
    if (isOutputRange!(Writer, string))
{
    immutable components = ["DMD Compiler", "Phobos", "Druntime", "dlang.org", "Optlink", "Tools", "Installer"];
    immutable bugtypes = ["regressions", "bugs", "enhancements"];

    foreach (component; components)
    {
        if (auto comp = component in entries)
        {
            foreach (bugtype; bugtypes)
            if (auto bugs = bugtype in *comp)
            {
                w.formattedWrite("$(BUGSTITLE_BUGZILLA %s %s,\n\n", component, bugtype);
                foreach (bug; sort!"a.id < b.id"(*bugs))
                {
                    w.formattedWrite("$(LI $(BUGZILLA %s): %s)\n",
                                        bug.id, bug.summary.escapeParens());
                }
                w.put(")\n");
            }
        }
    }
}

int main(string[] args)
{
    auto outputFile = "./changelog.dd";
    auto nextVersionString = "LATEST";

    auto currDate = Clock.currTime();
    auto nextVersionDate = "%s %02d, %04d"
        .format(currDate.month.to!string.capitalize, currDate.day, currDate.year);

    string previousVersion = "Previous version";
    bool hideTextChanges = false;
    string revRange;

    // TODO: no-op - remove me as soon as dlang.org is upgraded
    bool useNightlyTemplate;

    auto helpInformation = getopt(
        args,
        std.getopt.config.passThrough,
        "output|o", &outputFile,
        "date", &nextVersionDate,
        "version", &nextVersionString,
        "nightly", &useNightlyTemplate,
        "prev-version", &previousVersion, // this can automatically be detected
        "no-text", &hideTextChanges);

    if (helpInformation.helpWanted)
    {
`Changelog generator
Please supply a bugzilla version
./changed.d "v2.071.2..upstream/stable"`.defaultGetoptPrinter(helpInformation.options);
    }

    if (args.length >= 2)
    {
        revRange = args[1];

        // extract the previous version
        auto parts = revRange.split("..");
        if (parts.length > 1)
            previousVersion = parts[0].replace("v", "");
    }
    else
    {
        writeln("Skipped querying Bugzilla for changes. Please define a revision range e.g ./changed v2.072.2..upstream/stable");
    }

    auto f = File(outputFile, "w");
    auto w = f.lockingTextWriter();
    w.put("Ddoc\n\n");
    w.formattedWrite("$(CHANGELOG_NAV_LAST %s)\n\n", previousVersion);
    w.put("$(CHANGELOG_HEADER)\n");

    {
        w.formattedWrite("$(VERSION %s, =================================================,\n\n", nextVersionDate);

        scope(exit) w.put(")\n");

        if (!hideTextChanges)
        {
            // search for raw change files
            alias Repo = Tuple!(string, "path", string, "headline");
            auto repos = [Repo("dmd", "Compiler changes"),
                          Repo("druntime", "Runtime changes"),
                          Repo("phobos", "Library changes"),
                          Repo("dlang.org", "Language changes"),
                          Repo("installer", "Installer changes"),
                          Repo("tools", "Tools changes")];

            auto changedRepos = repos
                 .map!(repo => Repo(buildPath("..", repo.path, repo.path == "dlang.org" ? "language-changelog" : "changelog"), repo.headline))
                 .filter!(r => r.path.exists)
                 .map!(r => tuple!("headline", "changes")(r.headline, r.path.readTextChanges.array))
                 .filter!(r => !r.changes.empty);

            // print the overview headers
            changedRepos.each!(r => r.changes.writeTextChangesHeader(w, r.headline));

            if (!revRange.empty)
                w.put("$(CHANGELOG_SEP_HEADER_TEXT_NONEMPTY)\n\n");

            w.put("$(CHANGELOG_SEP_HEADER_TEXT)\n\n");

            // print the detailed descriptions
            changedRepos.each!(x => x.changes.writeTextChangesBody(w, x.headline));

            if (revRange.length)
                w.put("$(CHANGELOG_SEP_TEXT_BUGZILLA)\n\n");
        }
        else
        {
                w.put("$(CHANGELOG_SEP_NO_TEXT_BUGZILLA)\n\n");
        }

        // print the entire changelog history
        if (revRange.length)
            revRange.getBugzillaChanges.writeBugzillaChanges(w);
    }

    w.put("$(CHANGELOG_FOOTER)\n");
    w.formattedWrite("$(CHANGELOG_NAV_LAST %s)\n", previousVersion);

    // write own macros
    w.formattedWrite(`Macros:
    VER=%s
    TITLE=Change Log: $(VER)
    CHANGELOG_HEADER=
    CHANGELOG_FOOTER=
`, nextVersionString);

    writefln("Change log generated to: '%s'", outputFile);
    return 0;
}
