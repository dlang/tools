/*
 * Checks that all functions have a public example
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
import std.experimental.logger;
import std.range;
import std.stdio;
import utils;

bool hadError;

class TestVisitor : ASTVisitor
{

    this(string fileName, ubyte[] sourceCode)
    {
        this.fileName = fileName;
        this.sourceCode = sourceCode;
    }

    alias visit = ASTVisitor.visit;

    override void visit(const Module mod)
    {
        FunctionDeclaration lastFun;
        bool hasPublicUnittest;

        foreach (decl; mod.declarations)
        {
            if (!isPublic(decl.attributes))
                continue;

            if (decl.functionDeclaration !is null)
            {
                if (hasDitto(decl.functionDeclaration))
                    continue;

                if (lastFun !is null && !hasPublicUnittest)
                    triggerError(lastFun);

                if (hasDocComment(decl.functionDeclaration))
                    lastFun = cast(FunctionDeclaration) decl.functionDeclaration;
                else
                    lastFun = null;

                //debug {
                    //lastFun.name.text.writeln;
                //}
                hasPublicUnittest = false;
                continue;
            }

            if (decl.unittest_ !is null)
            {
                hasPublicUnittest |= validate(lastFun, decl);
                continue;
            }

            // ignore dittoed template declarations
            if (decl.templateDeclaration !is null)
                if (hasDitto(decl.templateDeclaration))
                    continue;

            // ignore dittoed struct declarations
            if (decl.structDeclaration !is null)
                if (hasDitto(decl.structDeclaration))
                    continue;

            // ran into struct or something else -> reset
            if (lastFun !is null && !hasPublicUnittest)
                triggerError(lastFun);

            lastFun = null;
        }

        if (lastFun !is null && !hasPublicUnittest)
            triggerError(lastFun);
    }

private:
    string fileName;
    ubyte[] sourceCode;

    void triggerError(const FunctionDeclaration decl)
    {
        stderr.writefln("%s:%d %s has no public unittest", fileName, decl.name.line, decl.name.text);
        hadError = true;
    }

    bool validate(const FunctionDeclaration lastFun, const Declaration decl)
    {
        // ignore module header unittest blocks or already validated functions
        if (lastFun is null)
            return true;

        if (!hasUnittestDdocHeader(sourceCode, decl))
            return false;

        return true;
    }

    bool hasDitto(Decl)(const Decl decl)
    {
        if (decl.comment is null)
            return false;

        if (decl.comment == "ditto")
            return true;

        if (decl.comment == "Ditto")
            return true;

        return false;
    }

    bool hasDocComment(Decl)(const Decl decl)
    {
        return decl.comment.length > 0;
    }

    bool isPublic(const Attribute[] attrs)
    {
        import dparse.lexer : tok;
        import std.algorithm.searching : any;
        import std.algorithm.iteration : map;

        enum tokPrivate = tok!"private", tokProtected = tok!"protected", tokPackage = tok!"package";

        if (attrs !is null)
            if (attrs.map!`a.attribute`.any!(x => x == tokPrivate || x == tokProtected || x == tokPackage))
                return false;

        return true;
    }
}

void parseFile(string fileName)
{
    import dparse.lexer;
    import dparse.parser : parseModule;
    import dparse.rollback_allocator : RollbackAllocator;
    import std.array : uninitializedArray;

    auto inFile = File(fileName, "r");
    if (inFile.size == 0)
        warningf("%s is empty", inFile.name);

    ubyte[] sourceCode = uninitializedArray!(ubyte[])(to!size_t(inFile.size));
    inFile.rawRead(sourceCode);
    LexerConfig config;
    auto cache = StringCache(StringCache.defaultBucketCount);
    auto tokens = getTokensForParser(sourceCode, config, &cache);

    RollbackAllocator rba;
    auto m = parseModule(tokens.array, fileName, &rba);
    auto visitor = new TestVisitor(fileName, sourceCode);
    visitor.visit(m);
}

void main(string[] args)
{
    import std.file;
    import std.getopt;
    import std.path : asNormalizedPath;

    string inputDir;
    string ignoredFilesStr;

    auto helpInfo = getopt(args, config.required,
            "inputdir|i", "Folder to start the recursive search for unittest blocks (can be a single file)", &inputDir,
            "ignore", "Comma-separated list of files to exclude (partial matching is supported)", &ignoredFilesStr);

    if (helpInfo.helpWanted)
    {
        return defaultGetoptPrinter(`example_validator
Searches the input directory recursively to ensure that all public functions
have a public unittest blocks, i.e.
unittest blocks that are annotated with three slashes (///).
`, helpInfo.options);
    }

    inputDir = inputDir.asNormalizedPath.array;

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
        if (!ignoringFiles.any!(x => file.name.canFind(x)))
            file.name.parseFile;

    import core.stdc.stdlib : exit;
    if (hadError)
        exit(1);
}
