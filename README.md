D tools
=======

[![GitHub tag](https://img.shields.io/github/tag/dlang/tools.svg?maxAge=86400)](https://github.com/dlang/tools/releases)
[![Bugzilla Issues](https://img.shields.io/badge/issues-Bugzilla-green.svg)](https://issues.dlang.org/buglist.cgi?component=tools&list_id=220149&product=D&resolution=---)
[![Buildkite](https://img.shields.io/buildkite/8cc605b3a89338bc41b144efcd5226acfe6b91c844a8a27ad9/master.svg?logo=dependabot&style=flat&label=buildkite)](https://buildkite.com/dlang/tools)
[![license](https://img.shields.io/github/license/dlang/tools.svg)](https://github.com/dlang/tools/blob/master/LICENSE.txt)

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
rdmd                   | Public   | [D build tool](http://dlang.org/rdmd.html).
rdmd_test              | Internal | rdmd test suite.
tests_extractor 	   | Internal | Extracts public unittests (requires DUB)
tolf                   | Internal | Line endings converter.
updatecopyright        | Internal | Update the copyright notices in DMD

To report a problem or browse the list of open bugs, please visit the
[bug tracker](http://issues.dlang.org/).

For a list and descriptions of D development tools, please visit the
[D wiki](http://wiki.dlang.org/Development_tools).

Building
--------

On a Posix system all tools can be built with:

```
make all
```

Using DUB as a build tool
-------------------------

Most tools can also be built with DUB:

```
dub build :ddemangle
```

Running DUB tools
-----------------

Some tools require D's package manager DUB.
By default, DUB builds a binary and executes it. On a Posix system,
the source files can directly be executed with DUB (e.g. `./tests_extractor.d`).
Alternatively, the full single file execution command can be used:

```
dub --single tests_extractor.d
```

Remember that when programs are run via DUB, you need to pass in `--` before
the program's arguments, e.g `dub --single tests_extractor.d -- -i ../phobos/std/algorithm`.

For more information, please see [DUB's documentation][dub-doc].

[dub-doc]: https://code.dlang.org/docs/commandline
