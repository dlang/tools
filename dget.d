//          Copyright Martin Nowak 2012.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)
module dget;

import std.algorithm, std.exception, std.file, std.range, std.net.curl;
static import std.stdio;
pragma(lib, "curl");

void usage()
{
    std.stdio.writeln("usage: dget [--clone|-c] [--help|-h] <repo>...");
}

int main(string[] args)
{
    if (args.length == 1) return usage(), 1;

    import std.getopt;
    bool clone, help;
    getopt(args,
           "clone|c", &clone,
           "help|h", &help);

    if (help) return usage(), 0;

    import std.typetuple;
    string user, repo;
    foreach(arg; args[1 .. $])
    {
        TypeTuple!(user, repo) = resolveRepo(arg);
        enforce(!repo.exists, fmt("output folder '%s' already exists", repo));
        if (clone) cloneRepo(user, repo);
        else fetchMaster(user, repo).unzipTo(repo);
    }
    return 0;
}

//::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

/// default github users for repo lookup
immutable defaultUsers = ["D-Programming-Deimos", "D-Programming-Language"];

auto resolveRepo(string arg)
{
    import std.regex;

    enum rule = regex(r"^(?:([^/:]*)/)?([^/:]*)$");
    auto m = match(arg, rule);
    enforce(!m.empty, fmt("expected 'user/repo' but found '%s'", arg));

    auto user = m.captures[1];
    auto repo = m.captures[2];

    if (user.empty)
    {
        auto tail = defaultUsers.find!(u => u.hasRepo(repo))();
        enforce(!tail.empty, fmt("repo '%s' was not found among '%(%s, %)'",
                                  repo, defaultUsers));
        user = tail.front;
    }
    import std.typecons;
    return tuple(user, repo);
}

bool hasRepo(string user, string repo)
{
    return fmt("https://api.github.com/users/%s/repos?type=public", user)
        .reqJSON().array.canFind!(a => a.object["name"].str == repo)();
}

//::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

void cloneRepo(string user, string repo)
{
    import std.process;
    enforce(!system(fmt("git clone git://github.com/%s/%s", user, repo)));
}

//::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

ubyte[] fetchMaster(string user, string repo)
{
    auto url = fmt("https://api.github.com/repos/%s/%s/git/refs/heads/master", user, repo);
    auto sha = url.reqJSON().object["object"].object["sha"].str;
    std.stdio.writefln("fetching %s/%s@%s", user, repo, sha);
    return download(fmt("https://github.com/%s/%s/zipball/master", user, repo));
}

//::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

auto reqJSON(string url)
{
    import std.json;
    return parseJSON(get(url));
}

//..............................................................................

ubyte[] download(string url)
{
    // doesn't work because it already timeouts after 2 minutes
    // return get!(HTTP, ubyte)();

    import core.time, std.array, std.conv;

    auto buf = appender!(ubyte[])();
    size_t contentLength;

    auto http = HTTP(url);
    http.method = HTTP.Method.get;
    http.onReceiveHeader((k, v)
    {
        if (k == "content-length")
            contentLength = to!size_t(v);
    });
    http.onReceive((data)
    {
        buf.put(data);
        std.stdio.writef("%sk/%sk\r", buf.data.length/1024,
                         contentLength ? to!string(contentLength/1024) : "?");
        std.stdio.stdout.flush();
        return data.length;
    });
    http.dataTimeout = dur!"msecs"(0);
    http.perform();
    immutable sc = http.statusLine().code;
    enforce(sc / 100 == 2 || sc == 302,
            fmt("HTTP request returned status code %s", sc));
    std.stdio.writeln("done                    ");
    return buf.data;
}

//..............................................................................

void unzipTo(ubyte[] data, string outdir)
{
    import std.path, std.string, std.zip;

    scope archive = new ZipArchive(data);
    std.stdio.writeln("unpacking:");
    string prefix;
    mkdir(outdir);

    foreach(name, _; archive.directory)
    {
        prefix = name[0 .. $ - name.find("/").length + 1];
        break;
    }
    foreach(name, am; archive.directory)
    {
        if (!am.expandedSize) continue;

        string path = buildPath(outdir, chompPrefix(name, prefix));
        std.stdio.writeln(path);
        auto dir = dirName(path);
        if (!dir.empty && !dir.exists)
            mkdirRecurse(dir);
        archive.expand(am);
        std.file.write(path, am.expandedData);
    }
}

//..............................................................................

string fmt(Args...)(string fmt, auto ref Args args)
{
    import std.array, std.format;
    auto app = appender!string();
    formattedWrite(app, fmt, args);
    return app.data;
}
