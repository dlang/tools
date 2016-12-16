#!/usr/bin/env dub
/+ dub.sdl:
name "tests_extractor"
dependency "libdparse" version="~>0.7.0-beta.2"
+/
/*
 * Parses all public unittests
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
import std.experimental.logger;
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
        auto prevLine = sourceCode[0 .. u.location].retro;
        prevLine.findSkip("\n"); // skip forward to the previous line
        auto ddocCommentSlashes = prevLine.until('\n').count('/');

        // only look for comments annotated with three slashes (///)
        if (ddocCommentSlashes != 3)
            return;

        // write the origin source code line
        outFile.writefln("// Line %d", u.line);

        // write the unittest block
        outFile.write("unittest\n{\n");
        scope(exit) outFile.writeln("}\n");

        // add an import to the current module
        outFile.writefln("    import %s;", moduleName);

        // write the content of the unittest block (but skip the first brace)
        auto k = cast(immutable(char)[]) sourceCode[u.blockStatement.startLocation .. u.blockStatement.endLocation];
        k.findSkip("{");
        outFile.write(k);

        // if the last line contains characters, we want to add an extra line for increased visual beauty
        if (k[$ - 1] != '\n')
            outFile.writeln;
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

    if (f.size == 0)
    {
        warningf("%s is empty", fileName);
        return;
    }

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
    string fileNameNormalized = (inputDir == "." ? fileName : fileName.replace(inputDir, ""));

    // remove leading dots or slashes
    while (!fileNameNormalized.empty && fileNameNormalized[0] == '.')
        fileNameNormalized = fileNameNormalized[1 .. $];
    if (fileNameNormalized.length >= dirSeparator.length &&
            fileNameNormalized[0 .. dirSeparator.length] == dirSeparator)
        fileNameNormalized = fileNameNormalized[dirSeparator.length .. $];

    // convert the file path to its module path, e.g. std/uni.d -> std.uni
    string moduleName = modulePrefix ~ fileNameNormalized.replace(".d", "")
                                                         .replace(dirSeparator, ".")
                                                         .replace(".package", "");

    // convert the file path to a nice output file, e.g. std/uni.d -> std_uni.d
    string outName = fileNameNormalized.replace(dirSeparator, "_");

    parseTests(fileName, moduleName, buildPath(outputDir, outName));
}

void main(string[] args)
{
    import std.getopt;

    string inputDir;
    string outputDir = "./out";
    string ignoredFilesStr;
    string modulePrefix = "";

    auto helpInfo = getopt(args, config.required,
            "inputdir|i", "Folder to start the recursive search for unittest blocks (can be a single file)", &inputDir,
            "outputdir|o", "Folder to which the extracted test files should be saved", &outputDir,
            "moduleprefix", "Module prefix to use for all files (e.g. std.algorithm)", &modulePrefix,
            "ignore", "Comma-separated list of files to exclude (partial matching is supported)", &ignoredFilesStr);

    if (helpInfo.helpWanted)
    {
        return defaultGetoptPrinter(`tests_extractor
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

    // if the module prefix is std -> add a dot for the next modules to follow
    if (!modulePrefix.empty)
        modulePrefix ~= '.';

    DirEntry[] files;

    if (inputDir.isFile)
    {
        files = [DirEntry(inputDir)];
        inputDir = ".";
    }
    else
    {
        files = dirEntries(inputDir, SpanMode.depth).filter!(
                a => a.name.endsWith(".d") && !a.name.canFind(".git")).array;
    }

    auto ignoringFiles = ignoredFilesStr.split(",");

    foreach (file; files)
    {
        if (!ignoringFiles.any!(x => file.name.canFind(x)))
        {
            writeln("parsing ", file);
            parseFile(inputDir, file, outputDir, modulePrefix);
        }
        else
        {
            writeln("ignoring ", file);
        }
    }
}
