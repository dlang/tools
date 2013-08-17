/++
This Windows-only tool automatically downloads Win32 libcurl binaries and
generates a libcurl.lib compatible with Win32 DMD (which is needed by
std.net.curl and certain official DMD tools).

There are no prerequisites other than an active internet connection and a
working D compiler to compile this tool.

This tool is provided because, unlike Posix and Win64, the standard libcurl
binaries aren't compatible with the DMD linker used on Win32. Instead, "implib"
needs to be used to generate a compatible import library from libcurl.dll,
which this tool handles automatically.
+/

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

version(Windows) {} else
{
    static assert(false,
        "This tool is only for Windows. On other systems, simply install "~
        "libcurl through your OS's usual package manager.");
}

auto outputDir = "dlibcurl32";

immutable unzipUrl      = "http://semitwist.com/download/app/unz600xn.exe";
immutable basicUtilsUrl = "http://ftp.digitalmars.com/bup.zip";
auto      curlUrl       = "http://curl.haxx.se/gknw.net/$(CURL_VERSION)/dist-w32/curl-$(CURL_VERSION)-rtmp-ssh2-ssl-sspi-zlib-idn-static-bin-w32.zip";
auto      curlZipBase   = "curl-$(CURL_VERSION)-rtmp-ssh2-ssl-sspi-zlib-idn-static-bin-w32";

immutable unzipArchiveName      = "unzip-sfx.exe";
immutable basicUtilsArchiveName = "bup.zip";
immutable curlArchiveName       = "curl.zip";

immutable workDirName       = "get_dlibcurl32";
immutable dloadToolFilename = "download.vbs";

immutable dloadToolContent =
`Option Explicit
Dim args, http, fileSystem, adoStream, url, target, status

Set args = Wscript.Arguments
Set http = CreateObject("WinHttp.WinHttpRequest.5.1")
url = args(0)
target = args(1)

http.Open "GET", url, False
http.Send
status = http.Status

If status <> 200 Then
    WScript.Echo "FAILED to download: HTTP Status " & status
    WScript.Quit 1
End If

Set adoStream = CreateObject("ADODB.Stream")
adoStream.Open
adoStream.Type = 1
adoStream.Write http.ResponseBody
adoStream.Position = 0

Set fileSystem = CreateObject("Scripting.FileSystemObject")
If fileSystem.FileExists(target) Then fileSystem.DeleteFile target
adoStream.SaveToFile target
adoStream.Close
`;

string workDir;
string dloadToolPath;
bool hasImplib;

void showHelp()
{
    stderr.writeln("Usage: get-dlibcurl32 LIBCURL_VERSION");
    stderr.writeln("Ex:    get-dlibcurl32 7.32.0");
}

int main(string[] args)
{
    if(args.length != 2)
    {
        showHelp();
        return 1;
    }
    
    if(args[1] == "--help")
    {
        showHelp();
        return 0;
    }
    
    // Setup paths
    auto curlVersion = args[1];
    curlUrl     = curlUrl    .replace("$(CURL_VERSION)", curlVersion);
    curlZipBase = curlZipBase.replace("$(CURL_VERSION)", curlVersion);
    outputDir ~= "-" ~ curlVersion;
    workDir = buildPath(tempDir(), workDirName);
    
    checkImplib();
    
    // Clear temporary work dir
    writeln("Clearing temporary work dir: ", workDir);
    removeDir(workDir);
    makeDir(workDir);
    
    // Archive paths
    auto unzipArchivePath        = buildPath(workDir, "unzip", unzipArchiveName);
    auto basicUtilsArchivePath   = buildPath(workDir, "bup",   basicUtilsArchiveName);
    auto curlArchivePath         = buildPath(workDir, curlArchiveName);
    makeDir(dirName(unzipArchivePath));
    makeDir(dirName(basicUtilsArchivePath));

    // Download
    initDownloader();
    download(unzipUrl, unzipArchivePath);
    if(!hasImplib)
        download(basicUtilsUrl, basicUtilsArchivePath);
    download(curlUrl, curlArchivePath);
    
    // Extract
    {
        auto saveDir = getcwd();
        scope(exit) chdir(saveDir);

        chdir(dirName(unzipArchivePath));
        run(unzipArchiveName); // Self-extracting archive

        if(!hasImplib)
        {
            chdir(dirName(basicUtilsArchivePath));
            unzip(basicUtilsArchiveName);
        }

        chdir(workDir);
        unzip(curlArchivePath);
    }
    
    // Generate import lib
    auto curlDir = buildPath(workDir, curlZipBase);
    implib(buildPath(curlDir, "libcurl"));
    
    // Copy results out of temp dir
    writeln("Copying results to '", outputDir, "'");
    removeDir(outputDir);
    copyDir(curlDir, outputDir);
    
    return 0;
}

string quote(string str)
{
    return `"` ~ str ~ `"`;
}

/// Recursively copy contents of 'src' directory into 'dest' directory.
/// Directory 'dest' will be created if it doesn't exist.
void copyDir(string src, string dest)
{
    // Needed to generate 'relativePath' correctly.
    if(!src.endsWith(dirSeparator))
        src ~= dirSeparator;
    
    makeDir(dest);
    foreach(DirEntry entry; dirEntries(src, SpanMode.breadth))
    {
        auto relativePath = entry.name.chompPrefix(src);

        auto destPath = buildPath(dest, relativePath);
        if(entry.isDir)
            makeDir(destPath);
        else
        {
            makeDir(dirName(destPath));
            copy(buildPath(src, relativePath), destPath);
        }
    }
}

/// Remove entire directory tree. If it doesn't exist, do nothing.
void removeDir(string path)
{
    if(exists(path))
    {
        auto failMsg = 
            "Failed to remove directory: "~path~"\n"~
            "    A process may still holding an open handle within the directory.\n"~
            "    Either delete the directory manually or try again later.";
        
        try
            system("rmdir /S /Q "~quote(path));
        catch(Exception e)
            throw new Exception(failMsg);

        if(exists(path))
            throw new Exception(failMsg);
    }
}

/// Like mkdirRecurse, but no error if directory already exists.
void makeDir(string path)
{
    if(!exists(path))
        mkdirRecurse(path);
}

void initDownloader()
{
    dloadToolPath = buildPath(workDir, dloadToolFilename);
    std.file.write(dloadToolPath, dloadToolContent);
}

void checkImplib()
{
    try
    {
        hasImplib = executeShell("implib /h").output.startsWith("Digital Mars Import Library Manager");
        writeln("NOCATCH: hasImplib: ", hasImplib);
    }
    catch(Exception e)
    {
        hasImplib = false;
        writeln("DID CATCH: hasImplib: ", hasImplib);
    }
}

void run(string cmd)
{
    auto errlevel = system(cmd);
    if(errlevel != 0)
        throw new Exception("Command failed: "~cmd~"\n  Ran from dir: "~getcwd());
}

void download(string url, string target)
{
    writeln("Downloading: ", url);
    run("cscript //Nologo "~quote(dloadToolPath)~" "~quote(url)~" "~quote(target));
}

void unzip(string path)
{
    writeln("Unzipping: ", path);
    auto unzipTool = buildPath(workDir, `unzip\unzip.exe`);
    run(unzipTool~" -q "~quote(path));
}

/// 'libName' includes path, but NOT extension
void implib(string libName)
{
    writeln("Generating Import Lib: ", libName);
    auto saveDir = getcwd();
    scope(exit) chdir(saveDir);

    chdir(dirName(libName));
    auto implibTool = hasImplib? "implib" : buildPath(workDir, `bup\dm\bin\implib.exe`);
    auto libBaseName = baseName(libName);
    run(implibTool~" /s "~quote(libBaseName~".lib")~" "~quote(libBaseName~".dll"));
}