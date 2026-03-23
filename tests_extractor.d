#!/usr/bin/env dub
/++dub.sdl:
name "tests_extractor"
dependency "libdparse" version="~>0.25.1"
+/
/*
 * Parses all public unittests that are visible on dlang.org
 * (= annotated with three slashes)
 *
 * Copyright (C) 2018 by D Language Foundation
 *
 * Author: Sebastian Wilzbach
 *
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
*/
// Written in the D programming language.

import dparse.ast;
import std.algorithm;
import std.ascii : whitespace;
import std.conv;
import std.exception;
import std.experimental.logger;
import std.file;
import std.path;
import std.range;
import std.stdio;

class TestVisitor : ASTVisitor
{
    File outFile;
    ubyte[] sourceCode;
    string moduleName;
    VisitorConfig config;

    this(File outFile, ubyte[] sourceCode, VisitorConfig config)
    {
        this.outFile = outFile;
        this.sourceCode = sourceCode;
        this.config = config;
    }

    alias visit = ASTVisitor.visit;

    override void visit(const Module m)
    {
        if (m.moduleDeclaration !is null)
        {
            moduleName = m.moduleDeclaration.moduleName.identifiers.map!(i => i.text).join(".");
        }
        else
        {
            // fallback: convert the file path to its module path, e.g. std/uni.d -> std.uni
            moduleName = outFile.name.replace(".d", "").replace(dirSeparator, ".").replace(".package", "");
        }
        m.accept(this);
        // -betterC doesn't run unittests out of the box
        if (config.betterCOutput)
        {
            outFile.writeln(q{extern(C) void main()
{
    static foreach(test; __traits(allMembers, mixin(__MODULE__)))
        static if (test.length > 8 && test[0..8] == "unittest")
            mixin(test)();
}});
        }
    }

    override void visit(const Declaration decl)
    {
        if (decl.unittest_ !is null && shouldIncludeUnittest(decl))
            print(decl.unittest_, decl.attributes);

        decl.accept(this);
    }

    override void visit(const ConditionalDeclaration decl)
    {
        bool skipTrue;

        // Check if it's a version that should be skipped
        if (auto vcd = decl.compileCondition.versionCondition)
        {
            const id = vcd.token.text;
            skipTrue = config.ignoredVersions.canFind(id);
        }

        // search if/version block
        if (!skipTrue)
        {
            foreach (d; decl.trueDeclarations)
                visit(d);
        }

        // Search else block
        foreach (d; decl.falseDeclarations)
            visit(d);
    }

private:

    bool shouldIncludeUnittest(const Declaration decl)
    {
        if (!config.attributes.empty)
            return filterForUDAs(decl);
        else
            return decl.unittest_.comment !is null;
    }

    bool filterForUDAs(const Declaration decl)
    {
        foreach (attr; decl.attributes)
        {
            if (attr.atAttribute is null)
                continue;

            // check for @myArg
            if (config.attributes.canFind(attr.atAttribute.identifier.text))
                return true;

            // support @("myArg") too
            if (auto argList = attr.atAttribute.argumentList)
            {
                foreach (arg; argList.items)
                {
                    if (auto unaryExp = cast(UnaryExpression) arg)
                    if (auto primaryExp = unaryExp.primaryExpression)
                    {
                        auto attribute = primaryExp.primary.text;
                        if (attribute.length >= 2)
                        {
                            attribute = attribute[1 .. $ - 1];
                            if (config.attributes.canFind(attribute))
                                return true;
                        }
                    }
                }
            }
        }
        return false;
    }
    void print(const Unittest u, const Attribute[] attributes)
    {
        /*
        Write the origin source code line
        u.line is the first line of the unittest block, hence we need to
        subtract two lines from it as we add "import <current.module>\n\n" at
        the top of the unittest.
        */
        const line = u.line > 2 ? u.line - 2 : 0;
        outFile.writefln("# line %d", line);

        static immutable predefinedAttributes = ["nogc", "system", "nothrow", "safe", "trusted", "pure"];

        // write system attributes
        foreach (attr; attributes)
        {
            // pure and nothrow
            if (attr.attribute.type != 0)
            {
                import dparse.lexer : str;
                const attrText = attr.attribute.type.str;
                outFile.write(text(attrText, " "));
            }

            const atAttribute = attr.atAttribute;
            if (atAttribute is null)
                continue;

            const atText = atAttribute.identifier.text;

            // ignore custom attributes (@myArg)
            if (!predefinedAttributes.canFind(atText))
                continue;

            outFile.write(text("@", atText, " "));
        }

        // write the unittest block
        if (config.betterCOutput)
            outFile.writef("void unittest_line_%s()\n{\n", line);
        else
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

void parseFile(File inFile, File outFile, VisitorConfig visitorConfig)
{
    import dparse.lexer;
    import dparse.parser : parseModule;
    import dparse.rollback_allocator : RollbackAllocator;
    import std.array : uninitializedArray;

    if (inFile.size == 0)
        warningf("%s is empty", inFile.name);

    ubyte[] sourceCode = uninitializedArray!(ubyte[])(to!size_t(inFile.size));
    inFile.rawRead(sourceCode);
    LexerConfig config;
    auto cache = StringCache(StringCache.defaultBucketCount);
    auto tokens = getTokensForParser(sourceCode, config, &cache);

    RollbackAllocator rba;
    auto m = parseModule(tokens.array, inFile.name, &rba);
    auto visitor = new TestVisitor(outFile, sourceCode, visitorConfig);
    visitor.visit(m);
}

void parseFileDir(string inputDir, string fileName, string outputDir, VisitorConfig visitorConfig)
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

    // convert the file path to a nice output file, e.g. std/uni.d -> std_uni.d
    string outName = fileNameNormalized.replace(dirSeparator, "_");

    parseFile(File(fileName), File(buildPath(outputDir, outName), "w"), visitorConfig);
}

struct VisitorConfig
{
    string[] attributes; /// List of attributes to extract;
    string[] ignoredVersions;   /// List of disabled version conditions
    bool betterCOutput; /// Add custom extern(C) main method for running D's unittests
}

void main(string[] args)
{
    import std.getopt;
    import std.variant : Algebraic, visit;

    string inputDir;
    string outputDir = "./out";
    string ignoredFilesStr;
    string modulePrefix;
    string attributesStr;
    string ignVersionsStr;
    VisitorConfig visitorConfig;

    auto helpInfo = getopt(args, config.required,
            "inputdir|i", "Folder to start the recursive search for unittest blocks (can be a single file)", &inputDir,
            "outputdir|o", "Folder to which the extracted test files should be saved (stdout for a single file)", &outputDir,
            "ignore", "Comma-separated list of files to exclude (partial matching is supported)", &ignoredFilesStr,
            "attributes|a", "Comma-separated list of UDAs that the unittest should have", &attributesStr,
            "undefinedVersions", "Comma-separated list of undefined versions", &ignVersionsStr,
            "betterC", "Add custom extern(C) main method for running D's unittests", &visitorConfig.betterCOutput,
    );

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
    Algebraic!(string, File) outputLocation = cast(string) outputDir.asNormalizedPath.array;
    visitorConfig.attributes = attributesStr.split(",");
    visitorConfig.ignoredVersions = ignVersionsStr.split(",");

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
        // for single files use stdout by default
        if (outputDir == "./out")
        {
            outputLocation = stdout;
        }
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
            stderr.writeln("parsing ", file);
            outputLocation.visit!(
                (string outputFolder) => parseFileDir(inputDir, file, outputFolder, visitorConfig),
                (File outputFile) => parseFile(File(file.name, "r"), outputFile, visitorConfig),
            );
        }
        else
        {
            stderr.writeln("ignoring ", file);
        }
    }
}

/**
The location of unittest token is known, but there might be attributes preceding it.
*/
private size_t getAttributesStartLocation(const Attribute[] attrs)
{
    import dparse.lexer : tok;

    if (attrs.length == 0)
        return size_t.max;

    if (attrs[0].atAttribute !is null)
        return attrs[0].atAttribute.startLocation;

    if (attrs[0].attribute != tok!"")
        return attrs[0].attribute.index;

    return size_t.max;
}

private size_t skipPreviousWord(const(ubyte)[] sourceCode, size_t index)
{
    return index - sourceCode[0 .. index]
                  .retro
                  .enumerate
                  .find!(c => !whitespace.canFind(c.value))
                  .find!(c => whitespace.canFind(c.value))
                  .front.index;
}
