#!/usr/bin/env rdmd

import core.stdc.stdlib;
import std.conv;
import std.stdio;
import std.file;
import std.datetime;
import std.zip;
import std.zlib;

int main(string[] args)
{
    if (args.length == 1)
    {
        stderr.writeln("Usage: zip zipfile attr members...");
        return EXIT_FAILURE;
    }

    if (args.length == 2)
    {
        auto zipname = args[1];
        auto buffer = cast(byte[])std.file.read(zipname);
        auto zr = new std.zip.ZipArchive(cast(void[])buffer);
        writefln("comment = '%s'", zr.comment);
        foreach (ArchiveMember de; zr.directory)
        {
            zr.expand(de);
            writefln("name = %s", de.name);
            writefln("\tcomment = %s", de.comment);
            writefln("\textractVersion = x%04x", de.extractVersion);
            writefln("\tflags = x%04x", de.flags);
            writefln("\tcompressionMethod = %d", de.compressionMethod);
            writefln("\tcrc32 = x%08x", de.crc32);
            writefln("\texpandedSize = %s", de.expandedSize);
            writefln("\tcompressedSize = %s", de.compressedSize);
            writefln("\teattr = %03o, %03o", de.fileAttributes);
            writefln("\tiattr = %03o", de.internalAttributes);
            writefln("\tdate = %s", SysTime(unixTimeToStdTime((de.time))));
        }
        return 0;
    }

    auto zipname = args[1];
    auto attr = args[2];
    auto members = args[3 .. $];

    uint newattr = 0;
    foreach (c; attr)
    {
        if (c < '0' || c > '7' || attr.length > 4)
            throw new ZipException("attr must be 1..4 octal digits, not " ~ attr);
        newattr = (newattr << 3) | (c - '0');
    }

    auto buffer = cast(byte[])std.file.read(zipname);
    auto zr = new std.zip.ZipArchive(cast(void[])buffer);

L1:
    foreach (member; members)
    {
        foreach (ArchiveMember de; zr.directory)
        {
            if (de.name == member)
                continue L1;
        }
        throw new ZipException(member ~ " not in zipfile " ~ zipname);
    }

    bool changes;
    foreach (ArchiveMember de; zr.directory)
    {
        zr.expand(de);

        foreach (member; members)
        {
            if (de.name == member && (de.fileAttributes & octal!7777) != newattr)
            {
                changes = true;
                de.fileAttributes = de.fileAttributes & ~octal!7777 | newattr;
                break;
            }
        }
    }

    if (changes)
    {
        void[] data2 = zr.build();
        std.file.write(zipname, cast(byte[])data2);
    }
    return 0;
}

