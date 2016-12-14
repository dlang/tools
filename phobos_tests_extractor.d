#!/usr/bin/env dub
/+ dub.sdl:
name "check_phobos"
dependency "libdparse" version="~>0.7.0-beta.2"
+/
/*
 * Parses all public unittests that are visible on dlang.org
 * (= annotated with three slashes)
 *
 * Copyright (C) 2016 by D Language Foundation
 *
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
*/
// Written in the D programming language.

import dparse.ast;
import std.algorithm;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.range;
import std.regex;
import std.stdio;
import std.string;

class TestVisitor : ASTVisitor
{
    File outFile;
    ubyte[] sourceCode;
    string moduleName;

    this(string outFileName, string moduleName, ubyte[] sourceCode)
    {
        this.outFile = File(outFileName, "w");
        this.moduleName = moduleName;
        this.sourceCode = sourceCode;
    }

    alias visit = ASTVisitor.visit;

    override void visit(const Unittest u)
    {
        // scan the previous line for ddoc header
        auto loc = u.location + 0;
        while (sourceCode[loc] != '\n')
            loc--;
        loc--;
        auto ddocComments = 0;
        while (sourceCode[loc] != '\n')
            if (sourceCode[loc--] == '/')
                ddocComments++;

        // only look for comments annotated with three slashes (///)
        if (ddocComments != 3)
            return;

        // write the origin source code line
        outFile.write("// Line ");
        outFile.write(sourceCode[0 .. loc].count("\n") + 2);
        outFile.write("\n");

        // write the unittest block and add an import to the current module
        outFile.write("unittest\n{\n");
        outFile.write("    import ");
        outFile.write(moduleName);
        outFile.write(";");
        auto k = cast(immutable(char)[]) sourceCode[u.blockStatement.startLocation
            + 0 .. u.blockStatement.endLocation];
        k.findSkip("{");
        outFile.write(k);
        outFile.writeln("}\n");
    }
}

void parseTests(string fileName, string moduleName, string outFileName)
{
    import dparse.lexer;
    import dparse.parser;
    import dparse.rollback_allocator;
    import std.array : uninitializedArray;

    assert(exists(fileName));

    File f = File(fileName);
    ubyte[] sourceCode = uninitializedArray!(ubyte[])(to!size_t(f.size));
    f.rawRead(sourceCode);
    LexerConfig config;
    StringCache cache = StringCache(StringCache.defaultBucketCount);
    auto tokens = getTokensForParser(sourceCode, config, &cache);
    RollbackAllocator rba;
    Module m = parseModule(tokens.array, fileName, &rba);
    auto visitor = new TestVisitor(outFileName, moduleName, sourceCode);
    visitor.visit(m);
}

void parseFile(string inputDir, string fileName, string outputDir, string modulePrefix = "")
{
    import std.path : buildPath, dirSeparator, buildNormalizedPath;

    // file name without its parent directory, e.g. std/uni.d
    string fileNameNormalized = (inputDir != ".") ? fileName.replace(inputDir,
            "")[1 .. $] : fileName[1 .. $];

    // convert the file path to its module path, e.g. std/uni.d -> std.uni
    string moduleName = modulePrefix ~ fileNameNormalized.replace(".d", "")
        .replace(dirSeparator, ".").replace(".package", "");

    // convert the file path to a nice output file, e.g. std/uni.d -> std_uni.d
    string outName = fileNameNormalized.replace("./", "").replace(dirSeparator, "_");

    parseTests(fileName, moduleName, buildPath(outputDir, outName));
}

void main(string[] args)
{
    import std.getopt;

    string inputDir;
    string outputDir = "./out";
    string ignoredFilesStr;

    auto helpInfo = getopt(args, config.required, "inputdir|i",
            "Folder to start the recursive search for unittest blocks (i.e. location to Phobos source)",
            &inputDir, "outputdir|o",
            "Folder to which the extracted test files should be saved",
            &outputDir, "ignore",
            "Comma-separated list of files to exclude (partial matching is supported)",
            &ignoredFilesStr,);

    if (helpInfo.helpWanted)
    {
        return defaultGetoptPrinter(`phobos_tests_extractor
Searches the input directory recursively for public unittest blocks, i.e.
unittest blocks that are annotated with three slashes (///).
The tests will be extracted as one file for each source file
to in the output directory.
`, helpInfo.options);
    }

    inputDir = inputDir.asNormalizedPath.array;
    outputDir = outputDir.asNormalizedPath.array;

    if (!exists(outputDir))
        mkdir(outputDir);

    auto files = dirEntries(inputDir, SpanMode.depth).array.filter!(
            a => a.name.endsWith(".d") && !a.name.canFind(".git"));

    auto ignoringFiles = ignoredFilesStr.split(",");

    foreach (file; files)
    {
        if (!ignoringFiles.any!(x => file.name.canFind(x)))
        {
            writeln("parsing ", file);
            parseFile(inputDir, file, outputDir);
        }
        else
        {
            writeln("ignoring ", file);
        }
    }
}
