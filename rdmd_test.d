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

    When running directly, pass the rdmd binary as the first argument.
*/

import std.algorithm;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.process;
import std.range;
import std.string;
import std.stdio;

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

int main(string[] args)
{
    string defaultCompiler; // name of default compiler expected by rdmd
    bool concurrencyTest;
    string model = "64"; // build architecture for dmd
    string testCompilerList; // e.g. "ldmd2,gdmd" (comma-separated list of compiler names)

    auto helpInfo = getopt(args,
        "rdmd-default-compiler", "[REQUIRED] default D compiler used by rdmd executable", &defaultCompiler,
        "concurrency", "whether to perform the concurrency test cases", &concurrencyTest,
        "m|model", "architecture to run the tests for [32 or 64]", &model,
        "test-compilers", "comma-separated list of D compilers to test with rdmd", &testCompilerList,
        "v|verbose", "verbose output", &verbose,
    );

    void reportHelp(string errorMsg = null, string file = __FILE__, size_t line = __LINE__)
    {
        defaultGetoptPrinter("rdmd_test: a test suite for rdmd\n\n" ~
                             "USAGE:\trdmd_test [OPTIONS] <rdmd_binary>\n",
                             helpInfo.options);
        enforce(errorMsg is null, errorMsg, file, line);
    }

    if (helpInfo.helpWanted || args.length == 1)
    {
        reportHelp();
        return 1;
    }

    if (args.length > 2)
    {
        writefln("Error: too many non-option arguments, expected 1 but got %s", args.length - 1);
        return 1; // fail
    }
    string rdmd = args[1]; // path to rdmd executable

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

    runCompilerAgnosticTests(rdmdApp, defaultCompiler, model);

    // if no explicit list of test compilers is set,
    // use the default compiler expected by rdmd
    if (testCompilerList is null)
        testCompilerList = defaultCompiler;

    // run the test suite for each specified test compiler
    foreach (testCompiler; testCompilerList.split(','))
    {
        // if compiler is a relative filename it must be converted
        // to absolute because this test changes directories
        if (testCompiler.canFind!isDirSeparator || testCompiler.exists)
            testCompiler = buildNormalizedPath(testCompiler.absolutePath);

        runTests(rdmdApp, testCompiler, model);
        if (concurrencyTest)
            runConcurrencyTest(rdmdApp, testCompiler, model);
    }

    return 0;
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

void runCompilerAgnosticTests(string rdmdApp, string defaultCompiler, string model)
{
    /* Test help string output when no arguments passed. */
    auto res = execute([rdmdApp]);
    enforce(res.status == 1, res.output);
    enforce(res.output.canFind("Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]..."));

    /* Test --help. */
    res = execute([rdmdApp, "--help"]);
    enforce(res.status == 0, res.output);
    enforce(res.output.canFind("Usage: rdmd [RDMD AND DMD OPTIONS]... program [PROGRAM OPTIONS]..."));

    string helpText = res.output;

    // verify help text matches expected defaultCompiler
    {
        version (Windows) helpText = helpText.replace("\r\n", "\n");
        enum compilerHelpLine = "  --compiler=comp    use the specified compiler (e.g. gdmd) instead of ";
        auto offset = helpText.indexOf(compilerHelpLine);
        enforce(offset >= 0);
        auto compilerInHelp = helpText[offset + compilerHelpLine.length .. $];
        compilerInHelp = compilerInHelp[0 .. compilerInHelp.indexOf('\n')];
        enforce(defaultCompiler.baseName == compilerInHelp,
            "Expected to find " ~ compilerInHelp ~ " in help text, found " ~ defaultCompiler ~ " instead");
    }

    /* Test that unsupported -o... options result in failure */
    res = execute([rdmdApp, "-o-"]);  // valid option for dmd but unsupported by rdmd
    enforce(res.status == 1, res.output);
    enforce(res.output.canFind("Option -o- currently not supported by rdmd"), res.output);

    res = execute([rdmdApp, "-o-foo"]); // should not be treated the same as -o-
    enforce(res.status == 1, res.output);
    enforce(res.output.canFind("Unrecognized option: o-foo"), res.output);

    res = execute([rdmdApp, "-opbreak"]); // should not be treated like valid -op
    enforce(res.status == 1, res.output);
    enforce(res.output.canFind("Unrecognized option: opbreak"), res.output);

    // run the fallback compiler test (this involves
    // searching for the default compiler, so cannot
    // be run with other test compilers)
    runFallbackTest(rdmdApp, defaultCompiler, model);
}

auto rdmdArguments(string rdmdApp, string compiler, string model)
{
    return [rdmdApp, compilerSwitch(compiler), modelSwitch(model)];
}

void runTests(string rdmdApp, string compiler, string model)
{
    // path to rdmd + common arguments (compiler, model)
    auto rdmdArgs = rdmdArguments(rdmdApp, compiler, model);

    /* Test --force. */
    string forceSrc = tempDir().buildPath("force_src_.d");
    std.file.write(forceSrc, `void main() { pragma(msg, "compile_force_src"); }`);

    auto res = execute(rdmdArgs ~ [forceSrc]);
    enforce(res.status == 0, res.output);
    enforce(res.output.canFind("compile_force_src"));

    res = execute(rdmdArgs ~ [forceSrc]);
    enforce(res.status == 0, res.output);
    enforce(!res.output.canFind("compile_force_src"));  // second call will not re-compile

    res = execute(rdmdArgs ~ ["--force", forceSrc]);
    enforce(res.status == 0, res.output);
    enforce(res.output.canFind("compile_force_src"));  // force will re-compile

    /* Test --build-only. */
    string failRuntime = tempDir().buildPath("fail_runtime_.d");
    std.file.write(failRuntime, "void main() { assert(0); }");

    res = execute(rdmdArgs ~ ["--force", "--build-only", failRuntime]);
    enforce(res.status == 0, res.output);  // only built, enforce(0) not called.

    res = execute(rdmdArgs ~ ["--force", failRuntime]);
    enforce(res.status == 1, res.output);  // enforce(0) called, rdmd execution failed.

    string failComptime = tempDir().buildPath("fail_comptime_.d");
    std.file.write(failComptime, "void main() { static assert(0); }");

    res = execute(rdmdArgs ~ ["--force", "--build-only", failComptime]);
    enforce(res.status == 1, res.output);  // building will fail for static enforce(0).

    res = execute(rdmdArgs ~ ["--force", failComptime]);
    enforce(res.status == 1, res.output);  // ditto.

    /* Test --chatty. */
    string voidMain = tempDir().buildPath("void_main_.d");
    std.file.write(voidMain, "void main() { }");

    res = execute(rdmdArgs ~ ["--force", "--chatty", voidMain]);
    enforce(res.status == 0, res.output);
    enforce(res.output.canFind("stat "));  // stat should be called.

    /* Test --dry-run. */
    res = execute(rdmdArgs ~ ["--force", "--dry-run", failComptime]);
    enforce(res.status == 0, res.output);  // static enforce(0) not called since we did not build.
    enforce(res.output.canFind("mkdirRecurse "), res.output);  // --dry-run implies chatty

    res = execute(rdmdArgs ~ ["--force", "--dry-run", "--build-only", failComptime]);
    enforce(res.status == 0, res.output);  // --build-only should not interfere with --dry-run

    /* Test --eval. */
    res = execute(rdmdArgs ~ ["--force", "-de", "--eval=writeln(`eval_works`);"]);
    enforce(res.status == 0, res.output);
    enforce(res.output.canFind("eval_works"));  // there could be a "DMD v2.xxx header in the output"

    // compiler flags
    res = execute(rdmdArgs ~ ["--force", "-debug",
        "--eval=debug {} else assert(false);"]);
    enforce(res.status == 0, res.output);

    // vs program file
    res = execute(rdmdArgs ~ ["--force",
        "--eval=assert(true);", voidMain]);
    enforce(res.status != 0);
    enforce(res.output.canFind("Cannot have both --eval and a program file ('" ~
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
    enforce(res.status == 0, res.output);

    string subModUser = tempDir().buildPath("subModUser_.d");
    std.file.write(subModUser, "module subModUser_; import dsubpack.submod; void main() { foo(); }");

    res = execute(rdmdArgs ~ ["--force", "--exclude=dsubpack", subModUser]);
    enforce(res.status == 1, res.output);  // building without the dependency fails

    res = execute(rdmdArgs ~ ["--force", "--exclude=dsubpack", subModObj, subModUser]);
    enforce(res.status == 0, res.output);  // building with the dependency succeeds

    /* Test --include. */
    auto packFolder2 = tempDir().buildPath("std");
    if (packFolder2.exists) packFolder2.rmdirRecurse();
    packFolder2.mkdirRecurse();
    scope (exit) packFolder2.rmdirRecurse();

    string subModSrc2 = packFolder2.buildPath("foo.d");
    std.file.write(subModSrc2, "module std.foo; void foobar() { }");

    std.file.write(subModUser, "import std.foo; void main() { foobar(); }");

    res = execute(rdmdArgs ~ ["--force", subModUser]);
    enforce(res.status == 1, res.output);  // building without the --include fails

    res = execute(rdmdArgs ~ ["--force", "--include=std", subModUser]);
    enforce(res.status == 0, res.output);  // building with the --include succeeds

    /* Test --extra-file. */

    string extraFileDi = tempDir().buildPath("extraFile_.di");
    std.file.write(extraFileDi, "module extraFile_; void f();");
    string extraFileD = tempDir().buildPath("extraFile_.d");
    std.file.write(extraFileD, "module extraFile_; void f() { return; }");
    string extraFileMain = tempDir().buildPath("extraFileMain_.d");
    std.file.write(extraFileMain,
            "module extraFileMain_; import extraFile_; void main() { f(); }");

    res = execute(rdmdArgs ~ ["--force", extraFileMain]);
    enforce(res.status == 1, res.output); // undefined reference to f()

    res = execute(rdmdArgs ~ ["--force",
            "--extra-file=" ~ extraFileD, extraFileMain]);
    enforce(res.status == 0, res.output); // now OK

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
        enforce(line == testLines.front, "Expected %s, got %s".format(testLines.front, line));
        testLines.popFront;
    }
    auto status = pipes.pid.wait();
    enforce(status == 0);
    }

    // vs program file
    res = execute(rdmdArgs ~ ["--force",
        "--loop=assert(true);", voidMain]);
    enforce(res.status != 0);
    enforce(res.output.canFind("Cannot have both --loop and a program file ('" ~
            voidMain ~ "')."));

    /* Test --main. */
    string noMain = tempDir().buildPath("no_main_.d");
    std.file.write(noMain, "module no_main_; void foo() { }");

    // test disabled: Optlink creates a dialog box here instead of erroring.
    /+ res = execute([rdmdApp, " %s", noMain));
    enforce(res.status == 1, res.output);  // main missing +/

    res = execute(rdmdArgs ~ ["--main", noMain]);
    enforce(res.status == 0, res.output);  // main added

    string intMain = tempDir().buildPath("int_main_.d");
    std.file.write(intMain, "int main(string[] args) { return args.length; }");

    res = execute(rdmdArgs ~ ["--main", intMain]);
    enforce(res.status == 1, res.output);  // duplicate main

    /* Test --makedepend. */

    string packRoot = packFolder.buildPath("../").buildNormalizedPath();

    string depMod = packRoot.buildPath("depMod_.d");
    std.file.write(depMod, "module depMod_; import dsubpack.submod; void main() { }");

    res = execute(rdmdArgs ~ ["-I" ~ packRoot, "--makedepend",
            "-of" ~ depMod[0..$-2], depMod]);

    import std.ascii : newline;

    // simplistic checks
    enforce(res.output.canFind(depMod[0..$-2] ~ ": \\" ~ newline));
    enforce(res.output.canFind(newline ~ " " ~ depMod ~ " \\" ~ newline));
    enforce(res.output.canFind(newline ~ " " ~ subModSrc));
    enforce(res.output.canFind(newline ~  subModSrc ~ ":" ~ newline));
    enforce(!res.output.canFind("\\" ~ newline ~ newline));

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
    enforce(output.canFind(depModFail[0..$-2] ~ ": \\" ~ newline));
    enforce(output.canFind(newline ~ " " ~ depModFail ~ " \\" ~ newline));
    enforce(output.canFind(newline ~ " " ~ subModSrc));
    enforce(output.canFind(newline ~ "" ~ subModSrc ~ ":" ~ newline));
    enforce(!output.canFind("\\" ~ newline ~ newline));
    enforce(res.status == 0, res.output);  // only built, enforce(0) not called.

    /* Test signal propagation through exit codes */

    version (Posix)
    {
        import core.sys.posix.signal;
        string crashSrc = tempDir().buildPath("crash_src_.d");
        std.file.write(crashSrc, `void main() { int *p; *p = 0; }`);
        res = execute(rdmdArgs ~ [crashSrc]);
        enforce(res.status == -SIGSEGV, format("%s", res));
    }

    /* -of doesn't append .exe on Windows: https://d.puremagic.com/issues/show_bug.cgi?id=12149 */

    version (Windows)
    {
        string outPath = tempDir().buildPath("test_of_app");
        string exePath = outPath ~ ".exe";
        res = execute(rdmdArgs ~ ["--build-only", "-of" ~ outPath, voidMain]);
        enforce(exePath.exists(), exePath);
    }

    /* Current directory change should not trigger rebuild */

    res = execute(rdmdArgs ~ [forceSrc]);
    enforce(res.status == 0, res.output);
    enforce(!res.output.canFind("compile_force_src"));

    {
        auto cwd = getcwd();
        scope(exit) chdir(cwd);
        chdir(tempDir);

        res = execute(rdmdArgs ~ [forceSrc.baseName()]);
        enforce(res.status == 0, res.output);
        enforce(!res.output.canFind("compile_force_src"));
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
    enforce(res.status != 0, "-of set to a directory should fail");

    res = execute(rdmdArgs ~ ["-of=" ~ conflictDir, forceSrc]);
    enforce(res.status != 0, "-of= set to a directory should fail");

    /* rdmd should force rebuild when --compiler changes: https://issues.dlang.org/show_bug.cgi?id=15031 */

    res = execute(rdmdArgs ~ [forceSrc]);
    enforce(res.status == 0, res.output);
    enforce(!res.output.canFind("compile_force_src"));

    auto fullCompilerPath = environment["PATH"]
        .splitter(pathSeparator)
        .map!(dir => dir.buildPath(compiler ~ binExt))
        .filter!exists
        .front;

    res = execute([rdmdApp, "--compiler=" ~ fullCompilerPath, modelSwitch(model), forceSrc]);
    enforce(res.status == 0, res.output ~ "\nCan't run with --compiler=" ~ fullCompilerPath);

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
        enforce(res.status == 0, res.output);

        TmpDir tmpdir = "rdmdTest";
        res = execute(rdmdArgs ~ ["--tmpdir=" ~ tmpdir, forceSrc, "--build-only"]);
        enforce(res.status == 0, res.output);
        enforce(res.output.canFind("compile_force_src"));
    }

    /* RDMD fails at building a lib when the source is in a subdir: https://issues.dlang.org/show_bug.cgi?id=14296 */
    {
        TmpDir srcDir = "rdmdTest";
        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void fun() {}`);
        if (exists("test" ~ libExt)) std.file.remove("test" ~ libExt);

        res = execute(rdmdArgs ~ ["--build-only", "--force", "-lib", srcName]);
        enforce(res.status == 0, res.output);
        enforce(exists(srcDir.buildPath("test" ~ libExt)));
        enforce(!exists("test" ~ libExt));
    }

    // Test with -od
    {
        TmpDir srcDir = "rdmdTestSrc";
        TmpDir libDir = "rdmdTestLib";

        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void fun() {}`);

        res = execute(rdmdArgs ~ ["--build-only", "--force", "-lib", "-od" ~ libDir, srcName]);
        enforce(res.status == 0, res.output);
        enforce(exists(libDir.buildPath("test" ~ libExt)));

        // test with -od= too
        TmpDir altLibDir = "rdmdTestAltLib";
        res = execute(rdmdArgs ~ ["--build-only", "--force", "-lib", "-od=" ~ altLibDir, srcName]);
        enforce(res.status == 0, res.output);
        enforce(exists(altLibDir.buildPath("test" ~ libExt)));
    }

    // Test with -of
    {
        TmpDir srcDir = "rdmdTestSrc";
        TmpDir libDir = "rdmdTestLib";

        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void fun() {}`);
        string libName = libDir.buildPath("libtest" ~ libExt);

        res = execute(rdmdArgs ~ ["--build-only", "--force", "-lib", "-of" ~ libName, srcName]);
        enforce(res.status == 0, res.output);
        enforce(exists(libName));

        // test that -of= works too
        string altLibName = libDir.buildPath("altlibtest" ~ libExt);

        res = execute(rdmdArgs ~ ["--build-only", "--force", "-lib", "-of=" ~ altLibName, srcName]);
        enforce(res.status == 0, res.output);
        enforce(exists(altLibName));
    }

    /* rdmd --build-only --force -c main.d fails: ./main: No such file or directory: https://issues.dlang.org/show_bug.cgi?id=16962 */
    {
        TmpDir srcDir = "rdmdTest";
        string srcName = srcDir.buildPath("test.d");
        std.file.write(srcName, `void main() {}`);
        string objName = srcDir.buildPath("test" ~ objExt);

        res = execute(rdmdArgs ~ ["--force", "-c", srcName]);
        enforce(res.status == 0, res.output);
        enforce(exists(objName));
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
        enforce(res.status == 0, res.output);
        enforce(exists(srcDir.buildPath("libfun" ~ libExt)));

        string mainSrcName = srcDir.buildPath("main.d");
        std.file.write(mainSrcName, `extern(C) void fun(); pragma(lib, "fun"); void main() { fun(); }`);

        res = execute(rdmdArgs ~ ["-L-L" ~ srcDir, mainSrcName]);
        enforce(res.status == 0, res.output);
    }}

    /* https://issues.dlang.org/show_bug.cgi?id=16966 */
    {
        immutable voidMainExe = setExtension(voidMain, binExt);
        res = execute(rdmdArgs ~ [voidMain]);
        enforce(res.status == 0, res.output);
        enforce(!exists(voidMainExe));
        res = execute(rdmdArgs ~ ["--build-only", voidMain]);
        enforce(res.status == 0, res.output);
        enforce(exists(voidMainExe));
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
        enforce(res.status == 1, res.output);

        res = execute(rdmdArgs ~ ["--extra-file=" ~ src2, src1]);
        enforce(res.status == 0, res.output);

        res = execute(rdmdArgs ~ [src1]);
        enforce(res.status == 1, res.output);
    }

    version (Posix)
    {
        import std.format : format;

        auto textOutput = tempDir().buildPath("rdmd_makefile_test.txt");
        if (exists(textOutput))
        {
            remove(textOutput);
        }
        enum makefileFormatter = `.ONESHELL:
SHELL = %s
.SHELLFLAGS = %-(%s %) --eval
%s:
	import std.file;
	write("$@","hello world\n");`;
        string makefileString = format!makefileFormatter(rdmdArgs[0], rdmdArgs[1 .. $], textOutput);
        auto makefilePath = tempDir().buildPath("rdmd_makefile_test.mak");
        std.file.write(makefilePath, makefileString);
        auto make = environment.get("MAKE") is null ? "make" : environment.get("MAKE");
        res = execute([make, "-f", makefilePath]);
        enforce(res.status == 0, res.output);
        enforce(std.file.read(textOutput) == "hello world\n");
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
            enforce(res.status == 0, res.output);
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
    string localDMD = buildPath(tempDir(), baseName(buildCompiler).setExtension(binExt));
    std.file.write(localDMD, ""); // An empty file avoids the "Not a valid 16-bit application" pop-up on Windows
    scope(exit) std.file.remove(localDMD);

    auto res = execute(rdmdApp ~ [modelSwitch(model), "--force", "--chatty", "--eval=writeln(`Compiler found.`);"]);
    enforce(res.status == 1, res.output);
    enforce(res.output.canFind(format(`spawn [%(%s%),`, localDMD.only)), localDMD ~ " would not have been executed");
}
