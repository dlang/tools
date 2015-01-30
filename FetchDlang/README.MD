
Contributions from the open source developer community have been critical to the evolution of D, and we want the developer experience to be as smooth as possible.

A script - fetchdlang - is available to make the process of fetching, building, and installing the latest sources automatic.  There are two versions: a linux shell script, and as a D program.

* Shell script
* D version (beta) - [source] [linux x86] [linux x64]


The bash script has been tested on Linux and OS X.  The D program works for Linux/Posix systems, but OS X is untested and Windows needs work.

Files are fetched from the following [https://github.com/D-Programming-Language github] repositories:

*[https://github.com/D-Programming-Language/druntime druntime]
*[https://github.com/D-Programming-Language/phobos phobos standard library]
*[https://github.com/D-Programming-Language/dmd dmd reference compiler]
*[https://github.com/D-Programming-Language/dlang.org dlang.org website source]
*[https://github.com/D-Programming-Language/tools ancillary D tools]


Requirements
============
You need to have git set up and configured in your path.  See documentation for your distribution/operating system for how to do this.  A github account is not necessary to install the source files, although you will need one if you wish to contribute to D.

For the shell script it is best to use zsh, although bash shoud also work.

For the D program, if you download the binary then there are no special dependencies.  To build from source you will need a working D compiler.  It has been tested with DMD and LDC and should work with GDC.  If you do not have a compiler installed yet, you can obtain it from the providers of your distribution (see here for availability) or download from dlang.org.

To build the sources you will need to have the appropriate compilers present and configured for your system.  The reference DMD compiler is mostly written in C++ for the time being, and so you will need g++ (or ???) as well as a D compiler, linker, and make.  The standard toolkit for linux is generally sufficient.

Use
===
# create a working directory where you would like the source files to be installed
# change to this directory
# run the installer from the directory.  eg /usr/sbin/fetchdlang for the D version or /usr/sbin/fetchdlang.sh for the bash script.  no arguments are required, although see below for options
# the following subdirectories will be created, each containing the latest sources from github: dmd,druntime,phobos,dlang.org,tools,installer
# after source has been fetched, the tool will build each component in turn

Arguments
=========
*If run without any arguments, the tool will fetch and build the latest sources from git - the default is to use 'master', which is bleeding edge and is not guaranteed to be free of problems (although the auto tester means it should compile).
*If the source files are already present as a local git repository, it will update them so that you have the latest version (and if they are not present, it will download them from scratch).


The following arguments may be added:
# install: this will copy over the D compiler from the dmd build directory and replace your local binary dmd.  This is not advisable for new users as it is generally better to develop using the released version and you run a risk that a newly built version from master may no longer be able to compile your source code.  If you run as a user normally, you will need to run the tool as sudo if you run your compiler from a system bin directory (/usr/bin, /usr/sbin, /usr/local/bin, etc)

# onlyinstall: this option is only available in the D version of the tool (not the shell script).  This will not fetch or build sources, but simply copy over the compiled D to your system install.

# --tag=XYZ: this will fetch, build, and (optionallly install) a tagged version from the repositories.  So if you wish to use DMD 2.067 beta 1 then you would do --tag=2.067.0-b1
Note that this prepends the specified tag argument by a 'v' so this will fetch the git tag v2.067.0-b1

# --cleanlocks: this option is only available in the D version.  Only use this if you are sure you know what you are doing.  Sometimes an incomplete download will lead git to lock some of the repositories, and to update them you will need to remove the .git/index.lock file that it leaves behind.  This option removes the lock, but can cause problems if the reason for the lock is that a concurrent instance of git is running.

