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
import std.conv : to;
import std.experimental.logger;
import std.range;
import std.stdio : File;

bool hasUnittestDdocHeader(ubyte[] sourceCode, const Declaration decl)
{
    import std.algorithm.comparison : min;
    import std.ascii : whitespace;
    import std.string : indexOf;

    const Unittest u = decl.unittest_;
    size_t firstPos = getAttributesStartLocation(sourceCode, decl.attributes, u.location);

    // scan the previous line for ddoc header -> skip to last real character
    auto prevLine = sourceCode[0 .. firstPos].retro.find!(c => whitespace.countUntil(c) < 0);

    auto ddocCommentSlashes = prevLine.until('\n').count('/');

    // only look for comments annotated with three slashes (///)
    if (ddocCommentSlashes == 3)
        return true;

    if (u.comment !is null)
    {
        // detect other common comment forms - be careful: reverse form
        // to be public it must start with either /** or /++
        auto lastTwoSymbols = prevLine.take(2);
        if (lastTwoSymbols.equal("/*"))
            return isDdocCommentLexer!'*'(prevLine.drop(2));
        if (prevLine.take(2).equal("/+"))
            return isDdocCommentLexer!'+'(prevLine.drop(2));
    }
	return false;
}

private auto isDdocCommentLexer(char symbol, Range)(Range r)
{
    size_t symbolSeen;
    foreach (s; r)
    {
        switch (s)
        {
            case symbol:
                symbolSeen++;
                break;
            case '/':
                if (symbolSeen > 0)
                    return symbolSeen > 1;
                break;
            default:
                symbolSeen = 0;
        }
    }
    warning("invalid comment structure detected");
    return false;
}

size_t getAttributesStartLocation(ubyte[] sourceCode, const Attribute[] attrs, size_t firstPos)
{
	import dparse.lexer : tok;
	if (attrs.length == 0)
	    return firstPos;

    // shortcut if atAttribute is the first attribute
    if (attrs[0].atAttribute !is null)
        return min(firstPos, attrs[0].atAttribute.startLocation);

    foreach_reverse (attr; attrs)
    {
        if (attr.atAttribute !is null)
            firstPos = min(firstPos, attr.atAttribute.startLocation);

        // if an attribute is defined we can safely jump over it
        if (attr.attribute.type != tok!"")
        {
            auto str = tokenRep(attr.attribute);
            auto whitespaceLength = sourceCode[0 .. firstPos].retro.countUntil(str.retro);
            firstPos -= str.length + whitespaceLength;
        }
    }
    return firstPos;
}

// from dparse.formatter
import dparse.lexer : str, Token, IdType;

string tokenRep(Token t)
{
    return t.text.length ? t.text : tokenRep(t.type);
}

string tokenRep(IdType t)
{
    return t ? str(t) : "";
}
