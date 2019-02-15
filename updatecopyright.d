#!/usr/bin/env rdmd

/**
Update the copyright notices in source files so that they have the form:
---
    Copyright XXXX-YYYY by The D Language Foundation, All Rights Reserved
---
It does not change copyright notices of authors that are known to have made
changes under a proprietary license.

Copyright:  Copyright (C) 2017-2018 by The D Language Foundation, All Rights Reserved

License:    $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0)

Authors:    Iain Buclaw

Example usage:

---
updatecopyright.d --update-year src/dmd
---
*/

module tools.updatecopyright;

int main(string[] args)
{
    import std.getopt;

    bool updateYear;
    bool verbose;
    auto opts = getopt(args,
        "update-year|y", "Update the current year on every notice", &updateYear,
        "verbose|v", "Be more verbose", &verbose);

    if (args.length == 1 || opts.helpWanted)
    {
        defaultGetoptPrinter("usage: updatecopyright [--help|-h] [--update-year|-y] <dir>...",
                             opts.options);
        return 0;
    }

    Copyright(updateYear, verbose).run(args[1 .. $]);
    return 0;
}

//::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

struct Copyright
{
    import std.algorithm : any, canFind, each, filter, joiner, map;
    import std.array : appender, array;
    import std.file : DirEntry, SpanMode, dirEntries, remove, rename;
    import std.stdio : File, stderr, stdout;
    import std.string : endsWith, strip, stripLeft, stripRight;
    import std.regex : Regex, matchAll, regex;

    // The author to use in copyright notices.
    enum author = "The D Language Foundation, All Rights Reserved";

    // The standard (C) form.
    enum copyright = "(C)";

private:
    // True if running in verbose mode.
    bool verbose = false;

    // True if also updating copyright year.
    bool updateYear = false;

    // An associative array of known copyright holders.
    // Value set to true if the copyright holder is internal.
    bool[string] holders;

    // Files and directories to ignore during search.
    static string[] skipDirs = [
        "docs",
        "ini",
        "test",
        "samples",
        "vcbuild",
        ".git",
    ];

    static string[] skipFiles = [
        "Jenkinsfile",
        "LICENSE.txt",
        "VERSION",
        ".a",
        ".ddoc",
        ".deps",
        ".lst",
        ".map",
        ".md",
        ".o",
        ".obj",
        ".sdl",
        ".sh",
        ".yml",
    ];

    // Characters in a range of years.
    // Include '.' for typos, and '?' for unknown years.
    enum rangesStr = `[0-9?](?:[-0-9.,\s]|\s+and\s+)*[0-9]`;

    // Non-whitespace characters in a copyright holder's name.
    enum nameStr = `[\w.,-]`;

    // Matches a full copyright notice:
    // - 'Copyright (C)', etc.
    // - The years. Includes the whitespace in the year, so that we can
    //   remove any excess.
    // - 'by ', if used
    // - The copyright holder.
    Regex!char copyrightRe;

    // A regexp for notices that might have slipped by.
    Regex!char otherCopyrightRe;

    // A regexp that matches one year.
    Regex!char yearRe;

    // Matches part of a year or copyright holder.
    Regex!char continuationRe;

    Regex!char commentRe;

    // Convenience for passing around file/line number information.
    struct FileLocation
    {
        string filename;
        size_t linnum;

        string toString()
        {
            import std.format : format;
            return "%s(%d)".format(this.filename, this.linnum);
        }
    }

    FileLocation location;
    char[] previousLine;

    void processFile(string filename)
    {
        import std.conv : to;

        // Looks like something we tried to create before.
        if (filename.endsWith(".tmp"))
        {
            remove(filename);
            return;
        }

        auto file = File(filename, "rb");
        auto output = appender!string;
        int errors = 0;
        bool changed = false;

        output.reserve(file.size.to!size_t);

        // Reset file location information.
        this.location = FileLocation(filename, 0);
        this.previousLine = null;

        foreach (line; file.byLine)
        {
            this.location.linnum++;
            try
            {
                changed |= this.processLine(line, output, errors);
            }
            catch (Exception)
            {
                if (this.verbose)
                    stderr.writeln(filename, ": bad input file");
                errors++;
                break;
            }
        }
        file.close();

        // If something changed, write the new file out.
        if (changed && !errors)
        {
            auto tmpfilename = filename ~ ".tmp";
            auto tmpfile = File(tmpfilename, "w");
            tmpfile.write(output.data);
            tmpfile.close();
            rename(tmpfilename, filename);
        }
    }

    bool processLine(String, Array)(String line, ref Array output, ref int errors)
    {
        bool changed = false;

        if (this.previousLine)
        {
            auto continuation = this.stripContinuation(line);

            // Merge the lines for matching purposes.
            auto mergedLine = this.previousLine.stripRight() ~ `, ` ~ continuation;
            auto mergedMatch = mergedLine.matchAll(copyrightRe);

            if (!continuation.matchAll(this.continuationRe) ||
                !mergedMatch || !this.isComplete(mergedMatch))
            {
                // If the next line doesn't look like a proper continuation,
                // assume that what we've got is complete.
                auto match = this.previousLine.matchAll(copyrightRe);
                changed |= this.updateCopyright(line, match, errors);
                output.put(this.previousLine);
                output.put('\n');
            }
            else
            {
                line = mergedLine;
            }
            this.previousLine = null;
        }

        auto match = line.matchAll(copyrightRe);
        if (match)
        {
            // If it looks like the copyright is incomplete, add the next line.
            if (!this.isComplete(match))
            {
                this.previousLine = line.dup;
                return changed;
            }
            changed |= this.updateCopyright(line, match, errors);
        }
        else if (line.matchAll(this.otherCopyrightRe))
        {
            stderr.writeln(this.location, ": unrecognised copyright: ", line.strip);
            //errors++; // Only treat this as a warning for now...
        }
        output.put(line);
        output.put('\n');

        return changed;
    }

    String stripContinuation(String)(String line)
    {
        line = line.stripLeft();
        auto match = line.matchAll(this.commentRe);
        if (match)
        {
            auto captures = match.front;
            line = captures.post.stripLeft();
        }
        return line;
    }

    bool isComplete(Match)(Match match)
    {
        auto captures = match.front;
        return captures.length >= 5 && captures[4] in this.holders;
    }

    bool updateCopyright(String, Match)(ref String line, Match match, ref int errors)
    {
        auto captures = match.front;
        if (captures.length < 5)
        {
            stderr.writeln(this.location, ": missing copyright holder");
            errors++;
            return false;
        }

        // See if copyright is associated with package author.
        // Update the author so as to be consistent everywhere.
        auto holder = captures[4];
        if (holder !in this.holders)
        {
            stderr.writeln(this.location, ": unrecognised copyright holder: ", holder);
            errors++;
            return false;
        }
        else if (!this.holders[holder])
            return false;

        // Update the copyright years.
        auto years = captures[2].strip;
        if (!this.canonicalizeYears(years))
        {
            stderr.writeln(this.location, ": unrecognised year string: ", years);
            errors++;
            return false;
        }

        // Make sure (C) is present.
        auto intro = captures[1];
        if (intro.endsWith("right"))
            intro ~= " " ~ this.copyright;
        else if (intro.endsWith("(c)"))
            intro = intro[0 .. $ - 3] ~ this.copyright;

        // Construct the copyright line, removing any 'by '.
        auto newline = captures.pre ~ intro ~ " " ~ years ~ " by " ~ this.author ~ captures.post;
        if (line != newline)
        {
            line = newline;
            return true;
        }
        return false;
    }

    bool canonicalizeYears(String)(ref String years)
    {
        import std.conv : to;
        import std.datetime : Clock;

        auto yearList = years.matchAll(this.yearRe).map!(m => m.front).array;
        if (yearList.length > 0)
        {
            auto minYear = yearList[0];
            auto maxYear = yearList[$ - 1];

            // Update the upper bound, if enabled.
            if (this.updateYear)
                maxYear = to!String(Clock.currTime.year);

            // Use a range.
            if (minYear == maxYear)
                years = minYear;
            else
                years = minYear ~ "-" ~ maxYear;
            return true;
        }
        return false;
    }

public:
    this(bool updateYear, bool verbose)
    {
        this.updateYear = updateYear;
        this.verbose = verbose;

        this.copyrightRe = regex(`([Cc]opyright` ~ `|[Cc]opyright\s+\([Cc]\))` ~
                                 `(\s*(?:` ~ rangesStr ~ `,?)\s*)` ~
                                 `(by\s+)?` ~
                                 `(` ~ nameStr ~ `(?:\s?` ~ nameStr ~ `)*)?`);
        this.otherCopyrightRe = regex(`copyright.*[0-9][0-9]`, `i`);
        this.yearRe = regex(`[0-9?]+`);
        this.continuationRe = regex(rangesStr ~ `|` ~ nameStr);
        this.commentRe = regex(`#+|[*]+|;+|//+`);

        this.holders = [
            "Digital Mars" : true,
            "Digital Mars, All Rights Reserved" : true,
            "The D Language Foundation, All Rights Reserved" : true,
            "The D Language Foundation" : true,

            // List of external authors.
            "Northwest Software" : false,
            "RSA Data Security, Inc. All rights reserved." : false,
            "Symantec" : false,
        ];
    }

    // Main loop.
    void run(string[] args)
    {
        // Returns true if entry should be skipped for processing.
        bool skipPath(DirEntry entry)
        {
            import std.path : baseName, dirName, pathSplitter;

            if (!entry.isFile)
                return true;

            if (entry.dirName.pathSplitter.filter!(d => this.skipDirs.canFind(d)).any)
                return true;

            auto basename = entry.baseName;
            if (this.skipFiles.canFind!(s => basename.endsWith(s)))
            {
                if (this.verbose)
                    stderr.writeln(entry, ": skipping file");
                return true;
            }
            return false;
        }

        args.map!(arg => arg.dirEntries(SpanMode.depth).filter!(a => !skipPath(a)))
            .joiner.each!(f => this.processFile(f));
    }
}
