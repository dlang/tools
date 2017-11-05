//
// Convert MingGW definition files to COFF import librries
//
// Distributed under the Boost Software License, Version 1.0.
//   (See accompanying file LICENSE_1_0.txt or copy at
//         http://www.boost.org/LICENSE_1_0.txt)
//
// usage: buildsdk [x86|x64] [def-folder] [output-folder] [msvcrt.def.in]
//
// Source files extracted from the MinGW reositories
//
// def-folder:    https://sourceforge.net/p/mingw/mingw-org-wsl/ci/5.0-active/tree/w32api/lib/
// msvcrt.def.in: https://sourceforge.net/p/mingw/mingw-org-wsl/ci/5.0-active/tree/mingwrt/msvcrt-xref/msvcrt.def.in
//
// assumes VC tools cl,link,lib and ml installed and found through path
//  and configured to the appropriate architecture
//

import std.file;
import std.regex;
import std.string;
import std.stdio;
import std.path;
import std.process;
import std.algorithm;

version = verbose;

void runShell(string cmd)
{
    version(verbose)
        writeln(cmd);
    auto rc = executeShell(cmd);
    if (rc.status)
    {
        writeln("'", cmd, "' failed with status ", rc.status);
        writeln(rc.output);
        throw new Exception("'" ~ cmd ~ "' failed");
    }
}

// x86: the exported symbols have stdcall mangling (including trailing @n)
// but the internal names of the platform DLLs have names with @n stripped off
// lib /DEF doesn't support renaming symbols so we have to go through compiling
// a C file with the symbols and building a DLL with renamed exports to get
// the appropriate import library
//
// x64: strip any @ from the symbol names
bool def2implib(bool x64, string f, string dir, string linkopt = null)
{
    static auto re = regex(r"@?([a-zA-Z0-9_]+)(@[0-9]*)");
    char[] content = cast(char[])std.file.read(f);
    auto pos = content.indexOf("EXPORTS");
    if (pos < 0)
        return false;

    char[] def = content[0..pos];
    char[] csrc;
    bool[string] written;
    auto lines = content[pos..$].splitLines;
    foreach(line; lines)
    {
        line = line.strip;
        if (line.length == 0 || line[0] == ';')
            continue;
        const(char)[] sym;
        char[] cline;
        auto m = matchFirst(line, re);
        if (m)
        {
            if (x64)
                def ~= m[1] ~ "\n";
            else
                def ~= m[0] ~ "=" ~  m[1] ~ "\n";
            sym = m[1];
            cline = "void " ~ m[1] ~ "() {}\n";
        }
        else
        {
            def ~= line ~ "\n";
            if (line.endsWith(" DATA"))
            {
                sym = strip(line[0..$-5]);
                cline = "int " ~ sym ~ ";\n";
            }
            else
            {
                auto idx = line.indexOf('=');
                if (idx > 0)
                    sym = line[idx+1 .. $].strip;
                else
                    sym = line;
                cline = "void " ~ sym ~ "() {}\n";
            }
        }
        if(sym.length && sym !in written)
        {
            csrc ~= cline;
            written[sym.idup] = true;
        }
    }
    string base = stripExtension(baseName(f));
    string dirbase = dir ~ base;
    std.file.write(dirbase ~ ".def", def);
    std.file.write(dirbase ~ ".c", csrc);

    runShell("cl /c /Fo" ~ dirbase ~ ".obj " ~ dirbase ~ ".c");
    runShell("link /NOD /NOENTRY /DLL " ~ dirbase ~ ".obj /out:" ~ dirbase ~ ".dll /def:" ~ dirbase ~ ".def" ~ linkopt);

    // cleanup
    std.file.remove(dirbase ~ ".def");
    std.file.remove(dirbase ~ ".c");
    std.file.remove(dirbase ~ ".obj");
    std.file.remove(dirbase ~ ".dll");
    std.file.remove(dirbase ~ ".exp");
    return true;
}

void buildLibs(bool x64, string defdir, string dir)
{
    mkdirRecurse(dir);

    //goto LnoDef;
    foreach(f; std.file.dirEntries(defdir, SpanMode.shallow))
        if (extension(f).toLower == ".def")
            def2implib(x64, f, dir);
    foreach(f; std.file.dirEntries(defdir ~ "/directx", SpanMode.shallow))
        if (extension(f).toLower == ".def")
            def2implib(x64, f, dir);

    version(DDK) // disable for now
    {
        mkdirRecurse(dir ~ ddk);
        foreach(f; std.file.dirEntries(defdir ~ "/ddk", SpanMode.shallow))
            if (extension(f).toLower == ".def")
                def2implib(x64, f, dir ~ "ddk/");
    }
}

void buildMsvcrt(bool x64, string dir, string msvcdef)
{
    string arch = x64 ? "x64" : "x86";
    string lib = "lib /MACHINE:" ~ arch ~ " ";
    string msvcrtlib = "msvcrt100.lib";

    // build msvcrt.lib for VS2010
    runShell("cl /EP -D__MSVCRT_VERSION__=0x10000000UL -D__DLLNAME__=msvcr100 " ~ msvcdef ~ " >" ~ dir ~ "msvcrt.def");
    runShell(lib ~ "/OUT:" ~ dir ~ msvcrtlib ~ " /DEF:" ~ dir ~ "msvcrt.def"); // no translation necessary
    runShell("cl /c /Zl /Fo" ~ dir ~ "msvcrt_stub0.obj /D_APPTYPE=0 msvcrt_stub.c");
    runShell("cl /c /Zl /Fo" ~ dir ~ "msvcrt_stub1.obj /D_APPTYPE=1 msvcrt_stub.c");
    runShell("cl /c /Zl /Fo" ~ dir ~ "msvcrt_stub2.obj /D_APPTYPE=2 msvcrt_stub.c");
    runShell("cl /c /Zl /Fo" ~ dir ~ "msvcrt_data.obj msvcrt_data.c");
    runShell("cl /c /Zl /Fo" ~ dir ~ "msvcrt_atexit.obj msvcrt_atexit.c");
    auto files = ["msvcrt_stub0.obj", "msvcrt_stub1.obj", "msvcrt_stub2.obj", "msvcrt_data.obj", "msvcrt_atexit.obj" ];
    if (!x64)
    {
        runShell("ml /c /Fo" ~ dir ~ "msvcrt_abs.obj msvcrt_abs.asm");
        files ~= "msvcrt_abs.obj";
    }
    auto objs = files.map!(a => dir ~ a).join(" ");
    runShell(lib ~ dir ~ msvcrtlib ~ " " ~ objs);

    // create oldnames.lib (expected by dmd)
    runShell("cl /c /Zl /Fo" ~ dir ~ "oldnames.obj oldnames.c");
    runShell(lib ~ "/OUT:" ~ dir ~ "oldnames.lib " ~ dir ~ "oldnames.obj");

    // create empty uuid.lib (expected by dmd, but UUIDs already in druntime)
    std.file.write(dir ~ "empty.c", "");
    runShell("cl /c /Zl /Fo" ~ dir ~ "uuid.obj " ~ dir ~ "empty.c");
    runShell(lib ~ "/OUT:" ~ dir ~ "uuid.lib " ~ dir ~ "uuid.obj");

    foreach(f; files)
        std.file.remove(dir ~ f);
    std.file.remove(dir ~ stripExtension(msvcrtlib) ~ ".exp");
    std.file.remove(dir ~ "msvcrt.def");
    std.file.remove(dir ~ "oldnames.obj");
    std.file.remove(dir ~ "uuid.obj");
    std.file.remove(dir ~ "empty.c");
}

void main(string[] args)
{
    bool x64 = (args.length > 1 && args[1] == "x64");
    string defdir = (args.length > 2 ? args[2] : "def");
    string outdir = x64 ? "lib64/" : "lib32mscoff/";
    if (args.length > 3)
        outdir = args[3] ~ "/";
    string msvcdef = (args.length > 4 ? args[4] : "msvcrt.def.in");

    buildLibs(x64, defdir, outdir);
    buildMsvcrt(x64, outdir, msvcdef);
}
