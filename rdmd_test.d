/*
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module rdmd_test;

/**
    RDMD Test-suite.

    Authors: Andrej Mitrovic

    Notes:
    Use the --compiler switch to specify a custom compiler to build RDMD and run the tests with.
    Use the --rdmd switch to specify the path to RDMD.
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
}
else version (Windows)
{
    enum objExt = ".obj";
    enum binExt = ".exe";
}
else
{
    static assert(0, "Unsupported operating system.");
}

string rdmdApp; // path/to/rdmd.exe (once built)
string compiler = "dmd";  // e.g. dmd/gdmd/ldmd

void main(string[] args)
{
    string rdmd = "rdmd.d";
    bool concurrencyTest;
    getopt(args,
        "compiler", &compiler,
        "rdmd", &rdmd,
        "concurrency", &concurrencyTest,
    );

    enforce(rdmd.exists, "Path to rdmd does not exist: %s".format(rdmd));

    rdmdApp = tempDir().buildPath("rdmd_app_") ~ binExt;
    if (rdmdApp.exists) std.file.remove(rdmdApp);

    auto res = execute([compiler, "-of" ~ rdmdApp, rdmd]);

    enforce(res.status == 0, res.output);
    enforce(rdmdApp.exists);

    runTests();
    if (concurrencyTest)
        runConcurrencyTest();
}

@property string compilerSwitch() { return "--compiler=" ~ compiler; }

void runTests()
{
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

    res = execute([rdmdApp, compilerSwitch, forceSrc]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("compile_force_src"));

    res = execute([rdmdApp, compilerSwitch, forceSrc]);
    assert(res.status == 0, res.output);
    assert(!res.output.canFind("compile_force_src"));  // second call will not re-compile

    res = execute([rdmdApp, compilerSwitch, "--force", forceSrc]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("compile_force_src"));  // force will re-compile

    /* Test --build-only. */
    string failRuntime = tempDir().buildPath("fail_runtime_.d");
    std.file.write(failRuntime, "void main() { assert(0); }");

    res = execute([rdmdApp, compilerSwitch, "--force", "--build-only", failRuntime]);
    assert(res.status == 0, res.output);  // only built, assert(0) not called.

    res = execute([rdmdApp, compilerSwitch, "--force", failRuntime]);
    assert(res.status == 1, res.output);  // assert(0) called, rdmd execution failed.

    string failComptime = tempDir().buildPath("fail_comptime_.d");
    std.file.write(failComptime, "void main() { static assert(0); }");

    res = execute([rdmdApp, compilerSwitch, "--force", "--build-only", failComptime]);
    assert(res.status == 1, res.output);  // building will fail for static assert(0).

    res = execute([rdmdApp, compilerSwitch, "--force", failComptime]);
    assert(res.status == 1, res.output);  // ditto.

    /* Test --chatty. */
    string voidMain = tempDir().buildPath("void_main_.d");
    std.file.write(voidMain, "void main() { }");

    res = execute([rdmdApp, compilerSwitch, "--force", "--chatty", voidMain]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("stat "));  // stat should be called.

    /* Test --dry-run. */
    res = execute([rdmdApp, compilerSwitch, "--force", "--dry-run", failComptime]);
    assert(res.status == 0, res.output);  // static assert(0) not called since we did not build.
    assert(res.output.canFind("stat "));  // --dry-run implies chatty, so stat is called.

    /* Test --eval. */
    res = execute([rdmdApp, compilerSwitch, "--force", "--eval=writeln(`eval_works`);"]);
    assert(res.status == 0, res.output);
    assert(res.output.canFind("eval_works"));  // there could be a "DMD v2.xxx header in the output"

    /* Test --exclude. */
    string packFolder = tempDir().buildPath("dsubpack");
    if (packFolder.exists) packFolder.rmdirRecurse();
    packFolder.mkdirRecurse();
    scope (exit) packFolder.rmdirRecurse();

    string subModObj = packFolder.buildPath("submod") ~ objExt;
    string subModSrc = packFolder.buildPath("submod.d");
    std.file.write(subModSrc, "module dsubpack.submod; void foo() { }");

    // build an object file out of the dependency
    res = execute([compiler, "-c", "-of" ~ subModObj, subModSrc]);
    assert(res.status == 0, res.output);

    string subModUser = tempDir().buildPath("subModUser_.d");
    std.file.write(subModUser, "module subModUser_; import dsubpack.submod; void main() { foo(); }");

    res = execute([rdmdApp, compilerSwitch, "--force", "--exclude=dsubpack", subModUser]);
    assert(res.status == 1, res.output);  // building without the dependency fails

    res = execute([rdmdApp, compilerSwitch, "--force", "--exclude=dsubpack", subModObj, subModUser]);
    assert(res.status == 0, res.output);  // building with the dependency succeeds

    /* Test --loop. */
    {
    auto testLines = "foo\nbar\ndoo".split("\n");

    auto pipes = pipeProcess([rdmdApp, compilerSwitch, "--force", "--loop=writeln(line);"], Redirect.stdin | Redirect.stdout);
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

    /* Test --main. */
    string noMain = tempDir().buildPath("no_main_.d");
    std.file.write(noMain, "module no_main_; void foo() { }");

    // test disabled: Optlink creates a dialog box here instead of erroring.
    /+ res = execute([rdmdApp, " %s", noMain));
    assert(res.status == 1, res.output);  // main missing +/

    res = execute([rdmdApp, compilerSwitch, "--main", noMain]);
    assert(res.status == 0, res.output);  // main added

    string intMain = tempDir().buildPath("int_main_.d");
    std.file.write(intMain, "int main(string[] args) { return args.length; }");

    res = execute([rdmdApp, compilerSwitch, "--main", intMain]);
    assert(res.status == 1, res.output);  // duplicate main

    /* Test --makedepend. */

    string packRoot = packFolder.buildPath("../").buildNormalizedPath();

    string depMod = packRoot.buildPath("depMod_.d");
    std.file.write(depMod, "module depMod_; import dsubpack.submod; void main() { }");

    res = execute([rdmdApp, compilerSwitch, "-I" ~ packRoot, "--makedepend", depMod]);
    assert(res.output.canFind("depMod_.d : "));  // simplistic check

}

void runConcurrencyTest()
{
    string sleep100 = tempDir().buildPath("delay_.d");
    std.file.write(sleep100, "void main() { import core.thread; Thread.sleep(100.msecs); }");
    auto argsVariants =
    [
        [rdmdApp, compilerSwitch, sleep100],
        [rdmdApp, compilerSwitch, "--force", sleep100],
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
