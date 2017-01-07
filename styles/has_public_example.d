/*
 * Checks that all functions have a public example
 *
 * Copyright (C) 2016 by D Language Foundation
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
        Declaration lastDecl;
        bool hasPublicUnittest;

        foreach (decl; mod.declarations)
        {
            if (!isPublic(decl.attributes))
                continue;

            if (decl.functionDeclaration !is null || decl.templateDeclaration !is null)
            {
                if (lastDecl !is null &&
                    (hasDitto(decl.functionDeclaration) || hasDitto(decl.templateDeclaration)))
                    continue;

                if (lastDecl !is null && !hasPublicUnittest)
                    triggerError(lastDecl);

                if (hasDdocHeader(sourceCode, decl))
                    lastDecl = cast(Declaration) decl;
                else
                    lastDecl = null;

                hasPublicUnittest = false;
                continue;
            }

            if (decl.unittest_ !is null)
            {
                // ignore module header unittest blocks or already validated functions
                hasPublicUnittest |= lastDecl is null || hasDdocHeader(sourceCode, decl);
                continue;
            }

            // ignore dittoed template declarations
            if (decl.classDeclaration !is null && hasDitto(decl.classDeclaration)
                || decl.structDeclaration !is null && hasDitto(decl.structDeclaration))
                    continue;

            // ran into struct or something else -> reset
            if (lastDecl !is null && !hasPublicUnittest)
                triggerError(lastDecl);

            lastDecl = null;
        }

        if (lastDecl !is null && !hasPublicUnittest)
            triggerError(lastDecl);
    }

private:
    string fileName;
    ubyte[] sourceCode;

    void triggerError(const Declaration decl)
    {
        if (auto fn = decl.functionDeclaration)
            stderr.writefln("function %s in %s:%d has no public unittest", fn.name.text, fileName, fn.name.line);
        if (auto tpl = decl.templateDeclaration)
            stderr.writefln("template %s in %s:%d has no public unittest", tpl.name.text, fileName, tpl.name.line);
        hadError = true;
    }

    bool hasDitto(Decl)(const Decl decl)
    {
        if (decl is null)
            return false;

        if (decl.comment is null)
            return false;

        if (decl.comment.among!("ditto", "Ditto"))
            return true;

        return false;
    }

    bool isPublic(const Attribute[] attrs)
    {
        import dparse.lexer : tok;
        import std.algorithm.searching : any;
        import std.algorithm.iteration : map;

        enum tokPrivate = tok!"private", tokProtected = tok!"protected", tokPackage = tok!"package";

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

    auto inFile = File(fileName);
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
        return defaultGetoptPrinter(`has_public_example
Searches the input directory recursively to ensure that all public, ddoced functions
have at least one public, ddoced unittest blocks.
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
