/*
 * Shared methods between style checkers
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
import std.ascii : whitespace;
import std.conv : to;
import std.experimental.logger;
import std.range;
import std.stdio : File;

bool hasDdocHeader(const(ubyte)[] sourceCode, const Declaration decl)
{
    import std.algorithm.comparison : min;

    bool hasComment;
    size_t firstPos = size_t.max;

    if (decl.unittest_ !is null) 
    {
        firstPos = decl.unittest_.location;
        hasComment = decl.unittest_.comment.length > 0;
    }
    else if (decl.functionDeclaration !is null) 
    {
        // skip the return type
        firstPos = sourceCode.skipPreviousWord(decl.functionDeclaration.name.index);
        if (auto stClasses = decl.functionDeclaration.storageClasses)
            firstPos = min(firstPos, stClasses[0].token.index);
        hasComment = decl.functionDeclaration.comment.length > 0;
    }
    else if (decl.templateDeclaration !is null) 
    {
        // skip the word `template`
        firstPos = sourceCode.skipPreviousWord(decl.templateDeclaration.name.index);
        hasComment = decl.templateDeclaration.comment.length > 0;
    }

    // libdparse will put any ddoc comment with at least one character in the comment field
    if (hasComment)
        return true;

    firstPos = min(firstPos, getAttributesStartLocation(decl.attributes));

    // scan the previous line for ddoc header -> skip to last real character
    auto prevLine = sourceCode[0 .. firstPos].retro.find!(c => whitespace.countUntil(c) < 0);

    // if there is no comment annotation, only three possible cases remain.
    // one line ddoc: ///, multi-line comments: /** */ or /++ +/
    return prevLine.filter!(c => !whitespace.canFind(c)).startsWith("///", "/+++/", "/***/") > 0;
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
