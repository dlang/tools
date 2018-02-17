#!/usr/bin/env rdmd

/**
Query contributors between two D releases.

Copyright: D Language Foundation 2017.

License:   $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).

Example usage:

---
./contributors.d "v2.074.0..v2.075.0"
---

Author: Sebastian Wilzbach
*/

import std.array;
import std.algorithm;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.process;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.typecons;

/// Name <my@email.com>
struct GitAuthor
{
    string name, email;
    string toString()
    {
        return "%s <%s>".format(name, email);
    }
}

/// Options for finding authors
struct FindConfig
{
    bool refreshTags; /// will query github.com for new tags
    bool noMerges; // will ignore merge commits
    bool showAllContributors; // will ignore the revRange and show all contributors
    string cwd; // working directory (should be tools)
    string mailmapFile; // location to the .mailmap file
}

/**
Search all git commit messages within revRange of all D repositories
Returns: Array that maps each git `Author: ...` line to a GitAuthor
*/
auto findAuthors(string revRange, FindConfig config)
{
    Appender!(GitAuthor[]) authors;
    int commits;
    auto repos = ["dmd", "druntime", "phobos", "dlang.org", "tools", "installer"];
    if (config.showAllContributors)
        repos ~= ["dub", "dub-registry", "dconf.org"];

    foreach (repo; repos.map!(r => buildPath(config.cwd, "..", r)))
    {
        if (!repo.exists)
        {
            stderr.writefln("Warning: %s doesn't exist. " ~
                            "Consider running: git clone https://github.com/dlang/%s ../%2$s",
                            repo, repo.baseName);
            continue;
        }
        if (config.refreshTags)
        {
            auto cmd = ["git", "-C", repo, "fetch", "--tags", "https://github.com/dlang/" ~ repo.baseName,
                               "+refs/heads/*:refs/remotes/upstream/*"];
            auto p = pipeProcess(cmd, Redirect.stdout);
            enforce(wait(p.pid) == 0, "Failed to execute '%(%s %)'.".format(cmd));
        }

        auto cmd = ["git", "-c", "mailmap.file=%s".format(config.mailmapFile), "-C", repo, "log", "--use-mailmap", "--pretty=format:%aN|%aE"];
        if (!config.showAllContributors)
            cmd ~= revRange;
        if (config.noMerges)
            cmd ~= "--no-merges";

        auto p = pipeProcess(cmd, Redirect.stdout);
        scope(exit) enforce(wait(p.pid) == 0, "Failed to execute '%(%s %)'.".format(cmd));

        authors ~= p.stdout
            .byLineCopy
            .tee!(_ => commits++)
            .map!((line){
                auto ps = line.splitter("|");
                return GitAuthor(ps.front, ps.dropOne.front);
            })
            .filter!(a => a.name != "The Dlang Bot");
    }
    if (!config.showAllContributors)
        stderr.writefln("Looked at %d commits in %s", commits, revRange);
    else
        stderr.writefln("Looked at %d commits", commits);
    return authors.data;
}

/// Sorts the authors and filters for duplicates
auto reduceAuthors(GitAuthors)(GitAuthors authors)
{
    import std.uni : sicmp;
    return authors
            .sort!((a, b) => sicmp(a.name, b.name) < 0)
            .uniq!((a, b) => a.name == b.name);
}

version(Contributors_Lib) {} else
int main(string[] args)
{
    import std.getopt;
    string revRange;
    FindConfig config = {
        cwd: __FILE_FULL_PATH__.dirName.asNormalizedPath.to!string,
    };
    config.mailmapFile = config.cwd.buildPath(".mailmap");

    enum PrintMode { name, markdown, ddoc, csv, git}
    PrintMode printMode;

    auto helpInformation = getopt(
        args,
        std.getopt.config.passThrough,
        "f|format", "Result format (name, markdown, ddoc, csv, git)", &printMode,
        "a|all", "Show all contributors", &config.showAllContributors,
        "refresh-tags", "Refresh tags", &config.refreshTags,
        "no-merges", "Ignore merge commits", &config.noMerges,
    );

    if (helpInformation.helpWanted || (args.length < 2 && !config.showAllContributors))
    {
`D contributors extractor.
./contributors.d "v2.075.0..v2.076.0"`.defaultGetoptPrinter(helpInformation.options);
        return 1;
    }

    revRange = args.length > 1 ? args[1] : null;
    revRange.findAuthors(config)
            .reduceAuthors
            .each!((a){
                with(PrintMode)
                final switch (printMode)
                {
                    case name: a.name.writeln; break;
                    case markdown: writefln("- %s", a.name); break;
                    case ddoc: writefln("$(D_CONTRIBUTOR %s)", a.name); break;
                    case csv: writefln("%s, %s", a.name, a.email); break;
                    case git: writefln("%s <%s>", a.name, a.email); break;
                }
            });
    return 0;
}
