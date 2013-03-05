///Written in the D programming language
/**
    A script to fetch bugfixes from  D Bugzilla between 
    given dates and print them out in DDoc form. 
*/
//NOTE: this script requires libcurl to be linked in (usually done by default)
module changed;
 
import std.net.curl, std.conv, std.exception, std.algorithm, std.csv, std.typecons,
    std.stdio, std.datetime, std.array, std.string, std.format, std.getopt;
 
auto templateRequest = 
    `http://d.puremagic.com/issues/buglist.cgi?username=crap2crap%40yandex.ru&password=powerlow7&chfieldto={to}&query_format=advanced&chfield=resolution&chfieldfrom={from}&bug_status=RESOLVED&resolution=FIXED&product=D&ctype=csv&columnlist=component%2Cbug_severity%2Cshort_desc`;
 
auto generateRequest(string templ, Date start, Date end)
{
    auto ss = format("%04s-%02s-%02s", start.year, to!int(start.month), start.day);
    auto es = format("%04s-%02s-%02s", end.year, to!int(end.month), end.day);
    return templateRequest.replace("{from}", ss).replace("{to}", es);
}
 
auto dateFromStr(string sdate)
{
    int year, month, day;
    formattedRead(sdate, "%s-%s-%s", &year, &month, &day);
    return Date(year, month, day);
}
 
struct Entry
{
    int id;
    string severity, summary;
}
 
int main(string[] args)
{
    string start_date, end_date;
    getopt(args,
        "start",  &start_date,    // numeric
        "end",    &end_date);      // string
    if(start_date.empty)
    {
        writefln("*ERROR: No start date set.\nUsage example:\n%s --start=YYYY-MM-DD [--end=YYYY-MM-DD] ", args[0]);
        return 1;
    }
    auto start = dateFromStr(start_date);
    auto end = end_date.empty ? to!Date(Clock.currTime()) : dateFromStr(end_date);
    auto req = generateRequest(templateRequest, start, end);
    debug stderr.writeln(req);
    auto data = req.get;
    Entry[] dmd, druntime, phobos;
    foreach(fields; csvReader!(Tuple!(int, string, string, string))(data, null))
    {
        switch(fields[1].toUpper()){
            case "DMD":
                dmd ~= Entry(fields[0], fields[2], fields[3].idup);
            break;
            case "DRUNTIME":
                druntime ~= Entry(fields[0], fields[2].idup, fields[3].idup);
            break;
            case "PHOBOS":
                phobos ~= Entry(fields[0], fields[2].idup, fields[3].idup);
            break;
            default:
                stderr.writeln("Skipping Issue ", fields[0], " Component: ", fields[1]);
        }
    }

    static void writeEntry(Entry e)
    {
        writefln("$(LI $(BUGZILLA %s): %s)", e.id, e.summary);
    }

    writeln("$(DMDBUGSFIXED ");
    foreach(e; sort!"a.id < b.id"(dmd))
        writeEntry(e);
    writeln(")");
    writeln("$(RUNTIMEBUGSFIXED ");
    foreach(e; sort!"a.id < b.id"(druntime))
        writeEntry(e);
    writeln(")");
    writeln("$(LIBBUGSFIXED ");
    foreach(e; sort!"a.id < b.id"(phobos))
        writeEntry(e);
    writeln(")");
    return 0;
} 