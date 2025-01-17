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
    std.path, std.functional, std.json, std.process;

import std.range.primitives, std.traits;

struct BugzillaEntry
{
    Nullable!int id;
    string summary;
    Nullable!int githubId;
}

struct GithubIssue
{
    int number;
    string title;
    string body_;
    string type;
    DateTime closedAt;
    Nullable!int bugzillaId;

    @property string summary() const
    {
        return this.title;
    }

    @property int id() const
    {
        return this.number;
    }
}

struct ChangelogEntry
{
    string title; // the first line (can't contain links)
    string description; // a detailed description (separated by a new line)
    string basename; // basename without extension (used for the anchor link to the description)
    string repo; // origin repository that contains the changelog entry
    string filePath; // path to the changelog entry (relative from the repository root)
}

struct ChangelogStats
{
    size_t bugzillaIssues; // number of referenced bugzilla issues of this release
    size_t changelogEntries; // number of changelog entries of this release
    size_t contributors; // number of distinct contributors that have contributed to this release

    /**
    Adds a changelog entry to the summary statistics.

    Params:
        entry = changelog entry
    */
    void addChangelogEntry(const ref ChangelogEntry entry)
    {
        changelogEntries++;
    }

    /**
    Adds a Bugzilla issue to the summary statistics.

    Params:
        entry = bugzilla entry
        component = component of the bugzilla issue (e.g. "dmd" or "phobos")
        type = type of the bugzilla issue (e.g. "regression" or "blocker")
    */
    void addBugzillaIssue(const ref BugzillaEntry, string component, string type)
    {
        bugzillaIssues++;
    }
}
ChangelogStats changelogStats;


// Also retrieve new (but not reopened) bugs, as bugs are only auto-closed when
// merged into master, but the changelog gets generated on stable.
auto templateRequest =
    `https://issues.dlang.org/buglist.cgi?bug_id={buglist}&bug_status=NEW&bug_status=RESOLVED&`~
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

Nullable!DateTime getFirstDateTime(string revRange)
{
    DateTime[] all;

    foreach (repo; ["dmd", "phobos", "dlang.org", "tools", "installer"]
             .map!(r => buildPath("..", r)))
    {
        auto cmd = ["git", "log", "--no-patch", "--no-notes"
            , "--date=format-local:%Y-%m-%dT%H:%M:%S", "--pretty=%cd"
            , revRange];
        auto p = pipeProcess(cmd, Redirect.stdout);
        all ~= p.stdout.byLine()
            .map!((char[] l) {
                auto r = DateTime.fromISOExtString(l);
                return r;
            })
            .array;
    }

    all.sort();

    return all.empty
        ? Nullable!(DateTime).init
        : all.front.nullable;
}

struct GitIssues
{
    int[] bugzillaIssueIds;
    int[] githubIssueIds;
}

/** Get a list of all bugzilla issues mentioned in revRange */
GitIssues getIssues(string revRange)
{
    import std.regex : ctRegex, match, splitter;

    // Keep in sync with the regex in dlang-bot:
    // https://github.com/dlang/dlang-bot/blob/master/source/dlangbot/bugzilla.d#L24
    // This regex was introduced in https://github.com/dlang/dlang-bot/pull/240
    // and only the first part of the regex is needed (the second part matches
    // issues reference that won't close the issue).
    // Note: "Bugzilla" is required since https://github.com/dlang/dlang-bot/pull/302;
    // temporarily both are accepted during a transition period.
    enum closedREBZ = ctRegex!(`(?:^fix(?:es)?(?:\s+bugzilla)?(?:\s+(?:issues?|bugs?))?\s+(#?\d+(?:[\s,\+&and]+#?\d+)*))`, "i");
    enum closedREGH = ctRegex!(`(?:^fix(?:es)?(?:\s+github)?(?:\s+(?:issues?|bugs?))?\s+(#?\d+(?:[\s,\+&and]+#?\d+)*))`, "i");

    auto issuesBZ = appender!(int[]);
    auto issuesGH = appender!(int[]);
    foreach (repo; ["dmd", "phobos", "dlang.org", "tools", "installer"]
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
            if (auto m = match(line.stripLeft, closedREBZ))
            {
                m.captures[1]
                    .splitter(ctRegex!`[^\d]+`)
                    .filter!(b => b.length)
                    .map!(to!int)
                    .copy(issuesBZ);
            }
            if (auto m = match(line.stripLeft, closedREGH))
            {
                m.captures[1]
                    .splitter(ctRegex!`[^\d]+`)
                    .filter!(b => b.length)
                    .map!(to!int)
                    .copy(issuesGH);
            }
        }
    }
    return GitIssues(issuesBZ.data.sort().release.uniq.array
            ,issuesGH.data.sort().release.uniq.array);
}

/** Generate and return the change log as a string. */
BugzillaEntry[][string /*type */][string /*comp*/] getBugzillaChanges(string revRange)
{
    // component (e.g. DMD) -> bug type (e.g. regression) -> list of bug entries
    BugzillaEntry[][string][string] entries;

    GitIssues issues = getIssues(revRange);
    // abort prematurely if no issues are found in all git logs
    if (issues.bugzillaIssueIds.empty)
    {
        return entries;
    }

    auto req = generateRequest(templateRequest, issues.bugzillaIssueIds);
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
            case "dub": comp = "Dub"; break;
            case "visuald": comp = "VisualD"; break;
            default: assert(0, comp);
        }

        string type = fields[2].toLower;
        switch (type)
        {
            case "regression":
                type = "regression fixes";
                break;

            case "blocker", "critical", "major", "normal", "minor", "trivial":
                type = "bug fixes";
                break;

            case "enhancement":
                type = "enhancements";
                break;

            default: assert(0, type);
        }

        auto entry = BugzillaEntry(fields[0].nullable(), fields[3].idup);
        entries[comp][type] ~= entry;
        changelogStats.addBugzillaIssue(entry, comp, type);
    }
    return entries;
}

Nullable!int getBugzillaId(string body_)
{
    string prefix = "### Transfered from https://issues.dlang.org/show_bug.cgi?id=";
    ptrdiff_t pIdx = body_.indexOf(prefix);
    Nullable!int ret;
    if (pIdx != -1)
    {
        ptrdiff_t newLine = body_.indexOf("\n", pIdx + prefix.length);
        if (newLine != -1)
        {
            ret = body_[pIdx + prefix.length .. newLine].to!int();
        }
    }
    return ret;
}

GithubIssue[][string /*type*/ ][string /*comp*/] getGithubIssuesRest(const DateTime startDate,
        const DateTime endDate, const string bearer)
{
    GithubIssue[][string][string] ret;
    string[2][] comps =
        [ [ "dlang.org", "dlang.org"]
        , [ "dmd", "DMD Compiler"]
        , [ "druntime", "Druntime"]
        , [ "phobos", "Phobos"]
        , [ "tools", "Tools"]
        , [ "dub", "Dub"]
        , [ "visuald", "VisualD"]
        ];
    foreach (it; comps)
    {
        GithubIssue[][string /* type */] tmp;
        GithubIssue[] ghi = getGithubIssuesRest("dlang", it[0], startDate,
                endDate, bearer);
        foreach (jt; ghi)
        {
            GithubIssue[]* p = jt.type in tmp;
            if (p !is null)
            {
                (*p) ~= jt;
            }
            else
            {
                tmp[jt.type] = [jt];
            }
        }
        ret[it[1]] = tmp;
    }
    return ret;
}

/**
Get closed issues of a github project

Params:
    project = almost always the dlang github project
    repo = the name of the repo to get the closed issues for
    endDate = the cutoff date for closed issues
    bearer = the classic github bearer token
*/
GithubIssue[] getGithubIssuesRest(const string project, const string repo
        , const DateTime startDate, const DateTime endDate, const string bearer)
{
    GithubIssue[] ret;
    foreach (page; 1 .. 100)
    { // 1000 issues per release should be enough
        string req = ("https://api.github.com/repos/%s/%s/issues?per_page=100"
            ~"&state=closed&since=%s&page=%s")
            .format(project, repo, startDate.toISOExtString() ~ "Z", page);

        HTTP http = HTTP(req);
        http.addRequestHeader("Accept", "application/vnd.github+json");
        http.addRequestHeader("X-GitHub-Api-Version", "2022-11-28");
        http.addRequestHeader("Authorization", bearer);

        char[] response;
        try
        {
            http.onReceive = (ubyte[] d)
            {
                response ~= cast(char[])d;
                return d.length;
            };
            http.perform();
        }
        catch(Exception e)
        {
            throw e;
        }

        string s = cast(string)response;
        JSONValue j = parseJSON(s);
        enforce(j.type == JSONType.array, j.toPrettyString()
                ~ "\nMust be an array");
        JSONValue[] arr = j.arrayNoRef();
        if (arr.empty)
        {
            break;
        }
        foreach (it; arr)
        {
            GithubIssue tmp;
            {
                const(JSONValue)* mem = "number" in it;
                enforce(mem !is null, it.toPrettyString()
                        ~ "\nmust contain 'number'");
                enforce((*mem).type == JSONType.integer, (*mem).toPrettyString()
                        ~ "\n'number' must be an integer");
                tmp.number = (*mem).get!int();
            }
            {
                const(JSONValue)* mem = "title" in it;
                enforce(mem !is null, it.toPrettyString()
                        ~ "\nmust contain 'title'");
                enforce((*mem).type == JSONType.string, (*mem).toPrettyString()
                        ~ "\n'title' must be an string");
                tmp.title = (*mem).get!string();
            }
            {
                const(JSONValue)* mem = "body" in it;
                enforce(mem !is null, it.toPrettyString()
                        ~ "\nmust contain 'body'");
                if ((*mem).type == JSONType.string)
                {
                    tmp.body_ = (*mem).get!string();
                    // get the possible bugzilla id
                    tmp.bugzillaId = getBugzillaId(tmp.body_);
                }
            }
            {
                const(JSONValue)* mem = "closed_at" in it;
                enforce(mem !is null, it.toPrettyString()
                        ~ "\nmust contain 'closed_at'");
                enforce((*mem).type == JSONType.string, (*mem).toPrettyString()
                        ~ "\n'closed_at' must be an string");
                string d = (*mem).get!string();
                d = d.endsWith("Z")
                    ? d[0 .. $ - 1]
                    : d;
                tmp.closedAt = DateTime.fromISOExtString(d);
            }
            {
                const(JSONValue)* mem = "labels" in it;
                tmp.type = "bug fixes";
                if (mem !is null)
                {
                    enforce(mem !is null, it.toPrettyString()
                            ~ "\nmust contain 'labels'");
                    enforce((*mem).type == JSONType.array, (*mem).toPrettyString()
                            ~ "\n'labels' must be an string");
                    foreach (l; (*mem).arrayNoRef())
                    {
                        enforce(l.type == JSONType.object, l.toPrettyString()
                                ~ "\nmust be an object");
                        const(JSONValue)* lbl = "name" in l;
                        enforce(lbl !is null, it.toPrettyString()
                                ~ "\nmust contain 'name'");
                        enforce((*lbl).type == JSONType.string, (*lbl).toPrettyString()
                                ~ "\n'name' must be an string");
                        string n = (*lbl).get!string();
                        switch (n)
                        {
                            case "regression":
                                tmp.type = "regression fixes";
                                break;

                            case "blocker", "critical", "major", "normal", "minor", "trivial":
                                tmp.type = "bug fixes";
                                break;

                            case "enhancement":
                                tmp.type = "enhancements";
                                break;
                            default:
                        }
                    }
                }
            }
            ret ~= tmp;
        }
        if (arr.length < 100)
        {
            break;
        }
    }
    return ret;
}

/**
Reads a single changelog file.

An entry consists of a title line, a blank separator line and
the description

Params:
    filename = changelog file to be parsed
    repoName = origin repository that contains the changelog entry

Returns: The parsed `ChangelogEntry`
*/
ChangelogEntry readChangelog(string filename, string repoName)
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
        basename: filename.baseName.stripExtension,
        repo: repoName,
        filePath: filename.findSplitAfter(repoName)[1].findSplitAfter("/")[1],
    };
    return entry;
}

/**
Looks for changelog files (ending with `.dd`) in a directory and parses them.

Params:
    changelogDir = directory to search for changelog files
    repoName = origin repository that contains the changelog entry

Returns: An InputRange of `ChangelogEntry`s
*/
auto readTextChanges(string changelogDir, string repoName, string prefix)
{
    import std.algorithm.iteration : filter, map;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName;
    import std.string : endsWith;

    return dirEntries(changelogDir, SpanMode.shallow)
            .filter!(a => a.name().endsWith(".dd"))
            .filter!(a => prefix is null || a.name().baseName.startsWith(prefix))
            .array.sort()
            .map!(a => readChangelog(a, repoName))
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
    foreach (change; changes)
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
    foreach (change; changes)
    {
        w.formattedWrite("$(LI $(LNAME2 %s,%s)\n", change.basename, change.title);
        w.formattedWrite("$(CHANGELOG_SOURCE_FILE %s, %s)\n", change.repo, change.filePath);
        scope(exit) w.put(")\n\n");

        bool inPara, inCode;
        foreach (line; change.description.splitLines)
        {
            if (line.stripLeft.startsWith("---", "```"))
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

bool lessImpl(ref BugzillaEntry a, ref BugzillaEntry b)
{
    if (!a.id.isNull() && !b.id.isNull())
    {
        return a.id.get() < b.id.get();
    }
    return false;
}

bool lessImpl(ref GithubIssue a, ref GithubIssue b)
{
    return a.number < b.number;
}

bool less(T)(ref T a, ref T b)
{
    return lessImpl(a, b);
}

enum BugzillaOrGithub {
    bugzilla,
    github
}

/**
Writes the fixed issued from Bugzilla in the ddoc format as a single list.

Params:
    changes = parsed InputRange of changelog information
    w = Output range to use
*/
void writeBugzillaChanges(Entries, Writer)(BugzillaOrGithub bog, Entries entries, Writer w)
    if (isOutputRange!(Writer, string))
{
    immutable components = ["DMD Compiler", "Phobos", "Druntime", "dlang.org", "Optlink", "Tools", "Installer"];
    immutable bugtypes = ["regression fixes", "bug fixes", "enhancements"];
    const string macroTitle = () {
        final switch(bog) {
            case BugzillaOrGithub.bugzilla: return "BUGSTITLE_BUGZILLA";
            case BugzillaOrGithub.github: return "BUGSTITLE_GITHUB";
        }
    }();
    const string macroLi = () {
        final switch(bog) {
            case BugzillaOrGithub.bugzilla: return "BUGZILLA";
            case BugzillaOrGithub.github: return "GITHUB";
        }
    }();

    foreach (component; components)
    {
        if (auto comp = component in entries)
        {
            foreach (bugtype; bugtypes)
            {
                if (auto bugs = bugtype in *comp)
                {
                    w.formattedWrite("$(%s %s %s,\n\n", macroTitle, component, bugtype);
                    alias lessFunc = less!(ElementEncodingType!(typeof(*bugs)));
                    foreach (bug; sort!lessFunc(*bugs))
                    {
                        w.formattedWrite("$(LI $(%s %s): %s)\n", macroLi,
                                            bug.id, bug.summary.escapeParens());
                    }
                    w.put(")\n");
                }
            }
        }
    }
}

int main(string[] args)
{
    auto outputFile = "./changelog.dd";
    auto nextVersionString = "LATEST";

    SysTime currDate = Clock.currTime();
    auto nextVersionDate = "%s %02d, %04d"
        .format(currDate.month.to!string.capitalize, currDate.day, currDate.year);

    string previousVersion = "Previous version";
    bool hideTextChanges = false;
    string revRange;
    string githubClassicTokenFileName;

    auto helpInformation = getopt(
        args,
        std.getopt.config.passThrough,
        "output|o", &outputFile,
        "date", &nextVersionDate,
        "ghToken|t", &githubClassicTokenFileName,
        "version", &nextVersionString,
        "prev-version", &previousVersion, // this can automatically be detected
        "no-text", &hideTextChanges);

    if (helpInformation.helpWanted)
    {
`Changelog generator
Please supply a bugzilla version
./changed.d "v2.071.2..upstream/stable"`.defaultGetoptPrinter(helpInformation.options);
    }

    assert(exists(githubClassicTokenFileName), format("No file with name '%s' exists"
            , githubClassicTokenFileName));
    const string githubToken = readText(githubClassicTokenFileName).strip();

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


    // location of the changelog files
    alias Repo = Tuple!(string, "name", string, "headline", string, "path", string, "prefix");
    auto repos = [Repo("dmd", "Compiler changes", "changelog", "dmd."),
                  Repo("dmd", "Runtime changes", "changelog", "druntime."),
                  Repo("phobos", "Library changes", "changelog", null),
                  Repo("dlang.org", "Language changes", "language-changelog", null),
                  Repo("installer", "Installer changes", "changelog", null),
                  Repo("tools", "Tools changes", "changelog", null),
                  Repo("dub", "Dub changes", "changelog", null)];

    auto changedRepos = repos
         .map!(repo => Repo(repo.name, repo.headline, buildPath(__FILE_FULL_PATH__.dirName, "..", repo.name, repo.path), repo.prefix))
         .filter!(r => r.path.exists);

    // ensure that all files either end on .dd or .md
    bool errors;
    foreach (repo; changedRepos)
    {
        auto invalidFiles = repo.path
            .dirEntries(SpanMode.shallow)
            .filter!(a => !a.name.endsWith(".dd", ".md"));
        if (!invalidFiles.empty)
        {
            invalidFiles.each!(f => stderr.writefln("ERROR: %s needs to have .dd or .md as extension", f.buildNormalizedPath));
            errors = 1;
        }
    }
    import core.stdc.stdlib : exit;
    if (errors)
        1.exit;

    auto f = File(outputFile, "w");
    auto w = f.lockingTextWriter();
    w.put("Ddoc\n\n");
    w.put("$(CHANGELOG_NAV_INJECT)\n\n");

    // Accumulate Bugzilla issues
    //typeof(revRange.getBugzillaChanges) bugzillaChanges;
    BugzillaEntry[][string][string] bugzillaChanges;
    if (revRange.length >= 0)
    {
        bugzillaChanges = getBugzillaChanges(revRange);
    }

    Nullable!(DateTime) firstDate = getFirstDateTime(revRange);
    enforce(!firstDate.isNull(), "Couldn't find a date from the revRange");
    GithubIssue[][string][string] githubChanges;
    if (revRange.length >= 0)
    {
        githubChanges = getGithubIssuesRest(firstDate.get(), cast(DateTime)currDate
                , githubToken);
    }

    // Accumulate contributors from the git log
    version(Contributors_Lib)
    {
        import contributors : FindConfig, findAuthors, reduceAuthors;
        typeof(revRange.findAuthors(FindConfig.init).reduceAuthors.array) authors;
        if (revRange)
        {
            FindConfig config = {
                cwd: __FILE_FULL_PATH__.dirName.asNormalizedPath.to!string,
            };
            config.mailmapFile = config.cwd.buildPath(".mailmap");
            authors = revRange.findAuthors(config).reduceAuthors.array;
            changelogStats.contributors = authors.save.walkLength;
        }
    }

    {
        w.formattedWrite("$(VERSION %s, =================================================,\n\n", nextVersionDate);

        scope(exit) w.put(")\n");


        if (!hideTextChanges)
        {
            // search for raw change files
            auto changelogDirs = changedRepos
                 .map!(r => tuple!("headline", "changes")(r.headline, r.path.readTextChanges(r.name, r.prefix).array))
                 .filter!(r => !r.changes.empty);

            // accumulate stats
            {
                changelogDirs.each!(c => c.changes.each!(c => changelogStats.addChangelogEntry(c)));
                w.put("$(CHANGELOG_HEADER_STATISTICS\n");
                scope(exit) w.put(")\n\n");

                with(changelogStats)
                {
                    auto changelog = changelogEntries > 0 ? "%d major change%s and".format(changelogEntries, changelogEntries > 1 ? "s" : "") : "";
                    w.put("$(VER) comes with {changelogEntries} {bugzillaIssues} fixed Bugzilla issue{bugzillaIssuesPlural}.
        A huge thanks goes to the
        $(LINK2 #contributors, {nrContributors} contributor{nrContributorsPlural})
        who made $(VER) possible."
                        .replace("{bugzillaIssues}", bugzillaIssues.text)
                        .replace("{bugzillaIssuesPlural}", bugzillaIssues != 1 ? "s" : "")
                        .replace("{changelogEntries}", changelog)
                        .replace("{nrContributors}", contributors.text)
                        .replace("{nrContributorsPlural}", contributors != 1 ? "s" : "")
                    );
                }
            }

            // print the overview headers
            changelogDirs.each!(c => c.changes.writeTextChangesHeader(w, c.headline));

            if (!revRange.empty)
                w.put("$(CHANGELOG_SEP_HEADER_TEXT_NONEMPTY)\n\n");

            w.put("$(CHANGELOG_SEP_HEADER_TEXT)\n\n");

            // print the detailed descriptions
            changelogDirs.each!(x => x.changes.writeTextChangesBody(w, x.headline));

            if (revRange.length)
                w.put("$(CHANGELOG_SEP_TEXT_BUGZILLA)\n\n");
        }
        else
        {
                w.put("$(CHANGELOG_SEP_NO_TEXT_BUGZILLA)\n\n");
        }

        // print the entire changelog history
        if (revRange.length)
        {
            writeBugzillaChanges(BugzillaOrGithub.bugzilla, bugzillaChanges, w);
        }
        if (revRange.length)
        {
            writeBugzillaChanges(BugzillaOrGithub.github, githubChanges, w);
        }
    }

    version(Contributors_Lib)
    if (revRange)
    {
        w.formattedWrite("$(D_CONTRIBUTORS_HEADER %d)\n", changelogStats.contributors);
        w.put("$(D_CONTRIBUTORS\n");
        authors.each!(a => w.formattedWrite("    $(D_CONTRIBUTOR %s)\n", a.name));
        w.put(")\n");
        w.put("$(D_CONTRIBUTORS_FOOTER)\n");
    }

    w.put("$(CHANGELOG_NAV_INJECT)\n\n");

    // write own macros
    w.formattedWrite(`Macros:
    VER=%s
    TITLE=Change Log: $(VER)
`, nextVersionString);

    writefln("Change log generated to: '%s'", outputFile);
    return 0;
}
