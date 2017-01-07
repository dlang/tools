D tools
=======

[![GitHub tag](https://img.shields.io/github/tag/dlang/tools.svg?maxAge=86400)](#)
[![Build Status](https://travis-ci.org/dlang/tools.svg?branch=master)](https://travis-ci.org/dlang/tools)
[![Issue Stats](https://img.shields.io/issuestats/p/github/dlang/tools.svg?maxAge=2592000)](http://www.issuestats.com/github/dlang/tools)

This repository hosts various tools redistributed with DMD or used
internally during various build tasks.

Program                | Scope    | Description
---------------------- | -------- | -----------------------------------------
catdoc                 | Build    | Concatenates Ddoc files.
changed                | Internal | Change log generator.
chmodzip               | Build    | ZIP file attributes editor.
ddemangle              | Public   | D symbol demangler.
detab                  | Internal | Replaces tabs with spaces.
dget                   | Internal | D source code downloader.
dman                   | Public   | D documentation lookup tool.
dustmite               | Public   | [Test case minimization tool](https://github.com/CyberShadow/DustMite/wiki).
get_dlibcurl32         | Internal | Win32 libcurl downloader/converter.
has_public_example 	   | Internal | Checks public functions for public examples (requires DUB)
rdmd                   | Public   | [D build tool](http://dlang.org/rdmd.html).
rdmd_test              | Internal | rdmd test suite.
tests_extractor 	   | Internal | Extracts public unittests (requires DUB)
tolf                   | Internal | Line endings converter.

To report a problem or browse the list of open bugs, please visit the
[bug tracker](http://issues.dlang.org/).

For a list and descriptions of D development tools, please visit the
[D wiki](http://wiki.dlang.org/Development_tools).

Running DUB tools
-----------------

Some tools require D's package manager DUB.
By default DUB builds a binary and executes it:

```
dub --root styles -c has_public_example
```

Remember that when programs are run via DUB, you need to pass in `--` before
the program's arguments, e.g `dub --root styles -c has_public_example -- -i ../phobos/std/algorithm`.

For more information, please see [DUB's documentation][dub-doc].

[dub-doc]: https://code.dlang.org/docs/commandline
