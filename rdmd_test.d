#!/usr/bin/env rdmd
/*
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module rdmd_test;

/**
    RDMD Test-suite.

    Authors: Andrej Mitrovic

    Note:
    While `rdmd_test` can be run directly, it is recommended to run
    it via the tools build scripts using the `make test_rdmd` target.

    When running directly, use the --rdmd flag to specify the path
    to the rdmd executable, to test, and --rdmd-default-compiler to
    specify the name of the default compiler expected by rdmd.
*/

import std.algorithm;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.process;
import std.range;
import std.string;

version (Posix)
{
    enum objExt = ".o";
    enum binExt = "";
    enum libExt = ".a";
}
else version (Windows)
{
    enum objExt = ".obj";
    enum binExt = ".exe";
    enum libExt = ".lib";
}
else
{
    static assert(0, "Unsupported operating system.");
}

bool verbose = false;

void main(string[] args)
{
    string rdmd; // path to rdmd executable
    string defaultCompiler; // name of default compiler expected by rdmd
    bool concurrencyTest;
    string model = "64"; // build architecture for dmd
    string testCompilerList; // e.g. "ldmd2,gdmd" (comma-separated list of compiler names)

    auto helpInfo = getopt(args,
        "rdmd", "[REQUIRED] path to rdmd executable to test", &rdmd,
        "rdmd-default-compiler", "[REQUIRED] default D compiler used by rdmd executable", &defaultCompiler,
        "concurrency", "whether to perform the concurrency test cases", &concurrencyTest,
        "m|model", "architecture to run the tests for [32 or 64]", &model,
        "test-compilers", "comma-separated list of D compilers to test with rdmd", &testCompilerList,
        "v|verbose", "verbose output", &verbose,
    );

    void reportHelp(string errorMsg = null, string file = __FILE__, size_t line = __LINE__)
    {
        defaultGetoptPrinter("rdmd_test: a test suite for rdmd\n\n" ~
                             "USAGE:\trdmd_test [OPTIONS]\n",
                             helpInfo.options);
        enforce(errorMsg is null, errorMsg, file, line);
    }

    if (helpInfo.helpWanted)
    {
        reportHelp();
        return;
    }

    if (rdmd.length == 0)
        reportHelp("ERROR: missing required --rdmd flag");

    if (defaultCompiler.length == 0)
        reportHelp("ERROR: missing required --rdmd-default-compiler flag");

    enforce(rdmd.exists,
            format("rdmd executable path '%s' does not exist", rdmd));

    // copy rdmd executable to temp dir: this enables us to set
    // up its execution environment with other features, e.g. a
    // dummy fallback compiler
    string rdmdApp = tempDir().buildPath("rdmd_app_") ~ binExt;
    scope (exit) std.file.remove(rdmdApp);
    copy(rdmd, rdmdApp, Yes.preserveAttributes);

    // if no explicit list of test compilers is set,
    // use the default compiler expected by rdmd
    if (testCompilerList is null)
        testCompilerList = defaultCompiler;

    // run the test suite for each specified test compiler
    foreach (testCompiler; testCompilerList.split(','))
    {
        runTests(rdmdApp, testCompiler, model);
        if (concurrencyTest)
            runConcurrencyTest(rdmdApp, testCompiler, model);
    }

    // run the fallback compiler test (this involves
    // searching for the default compiler, so cannot
    // be run with other test compilers)
    runFallbackTest(rdmdApp, defaultCompiler, model);
}

string compilerSwitch(string compiler) { return "--compiler=" ~ compiler; }

string modelSwitch(string model) { return "-m" ~ model; }

auto execute(T...)(T args)
{
    import std.stdio : writefln;
    if (verbose)
        writefln("[execute] %s", args[0]);
    return std.process.execute(args);
}

auto rdmdArguments(string rdmdApp, string compiler, string model)
{
    return [rdmdApp, compilerSwitch(compiler), modelSwitch(model)];
}

void runTests(string rdmdApp, string compiler, string model)
{
    // path to rdmd + common arguments (compiler, model)
    auto rdmdArgs = rdmdArguments(rdmdApp, compiler, model);

    /* Test help string output when no arguments passed. */
    auto res = execute([rdmdApp]);
    assert(res.status == 1, res.output);
    assert(res.output.canFind("Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]..."));

    /* Test --help. */
    res = execute([rdmdApp, "--help"]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]..."));

    /* Test --force. */
    string forceSrc = tempDir().buildPath("force_src_.d");
    std.file.write(forceSrc, `void main() { pragma(msg, "compile_force_src"); }`);

    res = execute(rdmdArgs ~ [forceSrc]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("compile_force_src"));

    res = execute(rdmdArgs ~ [forceSrc]);
    assert(res.status == 0, res.output);
    assert(!res.output.canFind("compile_force_src"));  // second call will not re-compile

    res = execute(rdmdArgs ~ ["--force", forceSrc]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("compile_force_src"));  // force will re-compile

    /* Test --build-only. */
    string failRuntime = tempDir().buildPath("fail_runtime_.d");
    std.file.write(failRuntime, "void main() { assert(0); }");

    res = execute(rdmdArgs ~ ["--force", "--build-only", failRuntime]);
    assert(res.status == 0, res.output);  // only built, assert(0) not called.

    res = execute(rdmdArgs ~ ["--force", failRuntime]);
    assert(res.status == 1, res.output);  // assert(0) called, rdmd execution failed.

    string failComptime = tempDir().buildPath("fail_comptime_.d");
    std.file.write(failComptime, "void main() { static assert(0); }");

    res = execute(rdmdArgs ~ ["--force", "--build-only", failComptime]);
    assert(res.status == 1, res.output);  // building will fail for static assert(0).

    res = execute(rdmdArgs ~ ["--force", failComptime]);
    assert(res.status == 1, res.output);  // ditto.

    /* Test --chatty. */
    string voidMain = tempDir().buildPath("void_main_.d");
    std.file.write(voidMain, "void main() { }");

    res = execute(rdmdArgs ~ ["--force", "--chatty", voidMain]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("stat "));  // stat should be called.

    /* Test --dry-run. */
    res = execute(rdmdArgs ~ ["--force", "--dry-run", failComptime]);
    assert(res.status == 0, res.output);  // static assert(0) not called since we did not build.
    assert(res.output.canFind("mkdirRecurse "), res.output);  // --dry-run implies chatty

    res = execute(rdmdArgs ~ ["--force", "--dry-run", "--build-only", failComptime]);
    assert(res.status == 0, res.output);  // --build-only should not interfere with --dry-run

    /* Test --eval. */
    res = execute(rdmdArgs ~ ["--force", "-de", "--eval=writeln(`eval_works`);"]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("eval_works"));  // there could be a "DMD v2.xxx header in the output"

    // compiler flags
    res = execute(rdmdArgs ~ ["--force", "-debug",
        "--eval=debug {} else assert(false);"]);
    assert(res.status == 0, res.output);

    // vs program file
    res = execute(rdmdArgs ~ ["--force",
        "--eval=assert(true);", voidMain]);
    assert(res.status != 0);
    assert(res.output.canFind("Cannot have both --eval and a program file ('" ~
            voidMain ~ "')."));

    /* Test --exclude. */
    string packFolder = tempDir().buildPath("dsubpack");
    if (packFolder.exists) packFolder.rmdirRecurse();
    packFolder.mkdirRecurse();
    scope (exit) packFolder.rmdirRecurse();

    string subModObj = packFolder.buildPath("submod") ~ objExt;
    string subModSrc = packFolder.buildPath("submod.d");
    std.file.write(subModSrc, "module dsubpack.submod; void foo() { }");

    // build an object file out of the dependency
    res = execute([compiler, modelSwitch(model), "-c", "-of" ~ subModObj, subModSrc]);
    assert(res.status == 0, res.output);

    string subModUser = tempDir().buildPath("subModUser_.d");
    std.file.write(subModUser, "module subModUser_; import dsubpack.submod; void main() { foo(); }");

    res = execute(rdmdArgs ~ ["--force", "--exclude=dsubpack", subModUser]);
    assert(res.status == 1, res.output);  // building without the dependency fails

    res = execute(rdmdArgs ~ ["--force", "--exclude=dsubpack", subModObj, subModUser]);
    assert(res.status == 0, res.output);  // building with the dependency succeeds

    /* Test --include. */
    auto packFolder2 = tempDir().buildPath("std");
    if (packFolder2.exists) packFolder2.rmdirRecurse();
    packFolder2.mkdirRecurse();
    scope (exit) packFolder2.rmdirRecurse();

    string subModSrc2 = packFolder2.buildPath("foo.d");
    std.file.write(subModSrc2, "module std.foo; void foobar() { }");

    std.file.write(subModUser, "import std.foo; void main() { foobar(); }");

    res = execute(rdmdArgs ~ ["--force", subModUser]);
    assert(res.status == 1, res.output);  // building without the --include fails

    res = execute(rdmdArgs ~ ["--force", "--include=std", subModUser]);
    assert(res.status == 0, res.output);  // building with the --include succeeds

    /* Test --extra-file. */

    string extraFileDi = tempDir().buildPath("extraFile_.di");
    std.file.write(extraFileDi, "module extraFile_; void f();");
    string extraFileD = tempDir().buildPath("extraFile_.d");
    std.file.write(extraFileD, "module extraFile_; void f() { return; }");
    string extraFileMain = tempDir().buildPath("extraFileMain_.d");
    std.file.write(extraFileMain,
            "module extraFileMain_; import extraFile_; void main() { f(); }");

    res = execute(rdmdArgs ~ ["--force", extraFileMain]);
    assert(res.status == 1, res.output); // undefined reference to f()

    res = execute(rdmdArgs ~ ["--force",
            "--extra-file=" ~ extraFileD, extraFileMain]);
    assert(res.status == 0, res.output); // now OK

    /* Test --loop. */
    {
    auto testLines = "foo\nbar\ndoo".split("\n");

    auto pipes = pipeProcess(rdmdArgs ~ ["--force", "--loop=writeln(line);"], Redirect.stdin | Redirect.stdout);
    foreach (input; testLines)
        pipes.stdin.writeln(input);
    pipes.stdin.close();

    while (!testLines.empty)
    {
        auto line = pipes.stdout.readln.strip;
        if (line.empty || line.startsWith("DMD v")) continue;  // git-head header
        assert(line == testLines.front, "Expected %s, got %s".format(testLines.front, line));
        testLines.popFront;
    }
    auto status = pipes.pid.wait();
    assert(status == 0);
    }

    // vs program file
    res = execute(rdmdArgs ~ ["--force",
        "--loop=assert(true);", voidMain]);
    assert(res.status != 0);
    assert(res.output.canFind("Cannot have both --loop and a program file ('" ~
            voidMain ~ "')."));

    /* Test --main. */
    string noMain = tempDir().buildPath("no_main_.d");
    std.file.write(noMain, "module no_main_; void foo() { }");

    // test disabled: Optlink creates a dialog box here instead of erroring.
    /+ res = execute([rdmdApp, " %s", noMain));
    assert(res.status == 1, res.output);  // main missing +/

    res = execute(rdmdArgs ~ ["--main", noMain]);
    assert(res.status == 0, res.output);  // main added

    string intMain = tempDir().buildPath("int_main_.d");
    std.file.write(intMain, "int main(string[] args) { return args.length; }");

    res = execute(rdmdArgs ~ ["--main", intMain]);
    assert(res.status == 1, res.output);  // duplicate main

    /* Test --makedepend. */

    string packRoot = packFolder.buildPath("../").buildNormalizedPath();

    string depMod = packRoot.buildPath("depMod_.d");
    std.file.write(depMod, "module depMod_; import dsubpack.submod; void main() { }");

    res = execute(rdmdArgs ~ ["-I" ~ packRoot, "--makedepend",
            "-of" ~ depMod[0..$-2], depMod]);

    import std.ascii : newline;

    // simplistic checks
    assert(res.output.canFind(depMod[0..$-2] ~ ": \\" ~ newline));
    assert(res.output.canFind(newline ~ " " ~ depMod ~ " \\" ~ newline));
    assert(res.output.canFind(newline ~ " " ~ subModSrc));
    assert(res.output.canFind(newline ~  subModSrc ~ ":" ~ newline));
    assert(!res.output.canFind("\\" ~ newline ~ newline));

    /* Test --makedepfile. */

    string depModFail = packRoot.buildPath("depModFail_.d");
    std.file.write(depModFail, "module depMod_; import dsubpack.submod; void main() { assert(0); }");

    string depMak = packRoot.buildPath("depMak_.mak");
    res = execute(rdmdArgs ~ ["--force", "--build-only",
            "-I" ~ packRoot, "--makedepfile=" ~ depMak,
            "-of" ~ depModFail[0..$-2], depModFail]);
    scope (exit) std.file.remove(depMak);

    string output = std.file.readText(depMak);

    // simplistic checks
    assert(output.canFind(depModFail[0..$-2] ~ ": \\" ~ newline));
    assert(output.canFind(newline ~ " " ~ depModFail ~ " \\" ~ newline));
    assert(output.canFind(newline ~ " " ~ subModSrc));
    assert(output.canFind(newline ~ "" ~ subModSrc ~ ":" ~ newline));
    assert(!output.canFind("\\" ~ newline ~ newline));
    assert(res.status == 0, res.output);  // only built, assert(0) not called.

    /* Test signal propagation through exit codes */

    version (Posix)
    {
        import core.sys.posix.signal;
        string crashSrc = tempDir().buildPath("crash_src_.d");
        std.file.write(crashSrc, `void main() { int *p; *p = 0; }`);
        res = execute(rdmdArgs ~ [crashSrc]);
        assert(res.status == -SIGSEGV, format("%s", res));
    }

    /* -of doesn't append .exe on Windows: https://d.puremagic.com/issues/show_bug.cgi?id=12149 */

    version (Windows)
    {
        string outPath = tempDir().buildPath("test_of_app");
        string exePath = outPath ~ ".exe";
        res = execute([rdmdApp, "--build-only", "-of" ~ outPath, voidMain]);
        enforce(exePath.exists(), exePath);
    }

    /* Current directory change should not trigger rebuild */

    res = execute(rdmdArgs ~ [forceSrc]);
    assert(res.status == 0, res.output);
    assert(!res.output.canFind("compile_force_src"));

    {
        auto cwd = getcwd();
        scope(exit) chdir(cwd);
        chdir(tempDir);

        res = execute(rdmdArgs ~ [forceSrc.baseName()]);
        assert(res.status == 0, res.output);
        assert(!res.output.canFind("compile_force_src"));
    }

    auto conflictDir = forceSrc.setExtension(".dir");
    if (exists(conflictDir))
    {
        if (isFile(conflictDir))
            remove(conflictDir);
        else
            rmdirRecurse(conflictDir);
    }
    mkdir(conflictDir);
    res = execute(rdmdArgs ~ ["-of" ~ conflictDir, forceSrc]);
    assert(res.status != 0, "-of set to a directory should fail");

    /* rdmd should force rebuild when --compiler changes: https://issues.dlang.org/show_bug.cgi?id=15031 */

    res = execute(rdmdArgs ~ [forceSrc]);
    assert(res.status == 0, res.output);
    assert(!res.output.canFind("compile_force_src"));

    auto fullCompilerPath = environment["PATH"]
        .splitter(pathSeparator)
        .map!(dir => dir.buildPath(compiler ~ binExt))
        .filter!exists
        .front;

    res = execute([rdmdApp, "--compiler=" ~ fullCompilerPath, forceSrc]);
    assert(res.status == 0, res.output ~ "\nCan't run with --compiler=" ~ fullCompilerPath);

    // Create an empty temporary directory and clean it up when exiting scope
    static struct TmpDir
    {
        string name;
        this(string name)
        {
            this.name = name;
            if (exists(name)) rmdirRecurse(name);
            mkdir(name);
        }
        @disable this(this);
        ~this()
        {
            version (Windows)
            {
                import core.thread;
                Thread.sleep(100.msecs); // Hack around Windows locking the directory
            }
            rmdirRecurse(name);
        }
        alias name this;
    }

    /* tmpdir */
    {
        res = execute(rdmdArgs ~ [forceSrc, "--build-only"]);
        assert(res.status == 0, res.output);

        TmpDir tmpdir = "rdmdTest";
        res = execute(rdmdArgs ~ ["--tmpdir=" ~ tmpdir, forceSrc, "--build-only"]);
        assert(res.status == 0, res.output);
        assert(res.output.canFind("compile_force_src"));
    }

    /* RDMD fails at building a lib when the source is in a subdir: https://issues.dlang.org/show_bug.cgi?id=14296 */
    {
        TmpDir srcDir = "rdmdTest";
        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void fun() {}`);
        if (exists("test" ~ libExt)) remove("test" ~ libExt);

        res = execute(rdmdArgs ~ ["--build-only", "--force", "-lib", srcName]);
        assert(res.status == 0, res.output);
        assert(exists(srcDir.buildPath("test" ~ libExt)));
        assert(!exists("test" ~ libExt));
    }

    // Test with -od
    {
        TmpDir srcDir = "rdmdTestSrc";
        TmpDir libDir = "rdmdTestLib";

        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void fun() {}`);

        res = execute(rdmdArgs ~ ["--build-only", "--force", "-lib", "-od" ~ libDir, srcName]);
        assert(res.status == 0, res.output);
        assert(exists(libDir.buildPath("test" ~ libExt)));
    }

    // Test with -of
    {
        TmpDir srcDir = "rdmdTestSrc";
        TmpDir libDir = "rdmdTestLib";

        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void fun() {}`);
        string libName = libDir.buildPath("libtest" ~ libExt);

        res = execute(rdmdArgs ~ ["--build-only", "--force", "-lib", "-of" ~ libName, srcName]);
        assert(res.status == 0, res.output);
        assert(exists(libName));
    }

    /* rdmd --build-only --force -c main.d fails: ./main: No such file or directory: https://issues.dlang.org/show_bug.cgi?id=16962 */
    {
        TmpDir srcDir = "rdmdTest";
        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void main() {}`);
        string objName = srcDir.buildPath("test" ~ objExt);

        res = execute(rdmdArgs ~ ["--force", "-c", srcName]);
        assert(res.status == 0, res.output);
        assert(exists(objName));
    }

    /* [REG2.072.0] pragma(lib) is broken with rdmd: https://issues.dlang.org/show_bug.cgi?id=16978 */
    /* GDC does not support `pragma(lib)`, so disable when test compiler is gdmd: https://issues.dlang.org/show_bug.cgi?id=18421
       (this constraint can be removed once GDC support for `pragma(lib)` is implemented) */

    version (linux)
    if (compiler.baseName != "gdmd")
    {{
        TmpDir srcDir = "rdmdTest";
        string libSrcName = srcDir.buildPath("libfun.d");
        std.file.write(libSrcName, `extern(C) void fun() {}`);

        res = execute(rdmdArgs ~ ["-lib", libSrcName]);
        assert(res.status == 0, res.output);
        assert(exists(srcDir.buildPath("libfun" ~ libExt)));

        string mainSrcName = srcDir.buildPath("main.d");
        std.file.write(mainSrcName, `extern(C) void fun(); pragma(lib, "fun"); void main() { fun(); }`);

        res = execute(rdmdArgs ~ ["-L-L" ~ srcDir, mainSrcName]);
        assert(res.status == 0, res.output);
    }}

    /* https://issues.dlang.org/show_bug.cgi?id=16966 */
    {
        immutable voidMainExe = setExtension(voidMain, binExt);
        res = execute(rdmdArgs ~ [voidMain]);
        assert(res.status == 0, res.output);
        assert(!exists(voidMainExe));
        res = execute(rdmdArgs ~ ["--build-only", voidMain]);
        assert(res.status == 0, res.output);
        assert(exists(voidMainExe));
        remove(voidMainExe);
    }

    /* https://issues.dlang.org/show_bug.cgi?id=17198 - rdmd does not recompile
    when --extra-file is added */
    {
        TmpDir srcDir = "rdmdTest";
        immutable string src1 = srcDir.buildPath("test.d");
        immutable string src2 = srcDir.buildPath("test2.d");
        std.file.write(src1, "int x = 1; int main() { return x; }");
        std.file.write(src2, "import test; static this() { x = 0; }");

        res = execute(rdmdArgs ~ [src1]);
        assert(res.status == 1, res.output);

        res = execute(rdmdArgs ~ ["--extra-file=" ~ src2, src1]);
        assert(res.status == 0, res.output);

        res = execute(rdmdArgs ~ [src1]);
        assert(res.status == 1, res.output);
    }
}

void runConcurrencyTest(string rdmdApp, string compiler, string model)
{
    // path to rdmd + common arguments (compiler, model)
    auto rdmdArgs = rdmdArguments(rdmdApp, compiler, model);

    string sleep100 = tempDir().buildPath("delay_.d");
    std.file.write(sleep100, "void main() { import core.thread; Thread.sleep(100.msecs); }");
    auto argsVariants =
    [
        rdmdArgs ~ [sleep100],
        rdmdArgs ~ ["--force", sleep100],
    ];
    import std.parallelism, std.range, std.random;
    foreach (rnd; rndGen.parallel(1))
    {
        try
        {
            auto args = argsVariants[rnd % $];
            auto res = execute(args);
            assert(res.status == 0, res.output);
        }
        catch (Exception e)
        {
            import std.stdio;
            writeln(e);
            break;
        }
    }
}

void runFallbackTest(string rdmdApp, string buildCompiler, string model)
{
    /* https://issues.dlang.org/show_bug.cgi?id=11997
       if an explicit --compiler flag is not provided, rdmd should
       search its own binary path first when looking for the default
       compiler (determined by the compiler used to build it) */
    string localDMD = buildPath(tempDir(), baseName(buildCompiler));
    std.file.write(localDMD, "empty shell");
    scope(exit) std.file.remove(localDMD);

    auto res = execute(rdmdApp ~ [modelSwitch(model), "--force", "--chatty", "--eval=writeln(`Compiler found.`);"]);
    assert(res.status == 1, res.output);
    assert(res.output.canFind(`spawn ["` ~ localDMD ~ `",`));
}
