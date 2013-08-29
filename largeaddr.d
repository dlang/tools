import std.array;
import std.stdio;
import std.stream;
import std.string;

alias std.stream.File File;

class UnsupportedExe : Exception
{
    this(string msg) { super(msg); }
}

ubyte[size] readBytes(int size)(File file)
{
    ubyte[size] bytes;
    foreach(i; 0..size)
        file.read(bytes[i]);
    
    return bytes;
}

ubyte readByte(File file)
{
    ubyte b;
    file.read(b);
    return b;
}

/// Phobos docs say that File.read(out ulong) is implementation-specific
ulong readULong(File file)
{
    auto bytes = file.readBytes!4();

    // Ensure proper byte order, regardless of endian-ness
    ulong result =
        bytes[0] <<  0 |
        bytes[1] <<  8 |
        bytes[2] << 16 |
        bytes[3] << 24;
    
    return result;
}

/// Note: This consumes 'size' bytes of input
void verifyMagic(int size)(File file, ubyte[size] expected)
{
    immutable failMsg = "File doesn't match expected exe format.";
    
    // Enough bytes remaining?
    if(file.position + size > file.size)
        throw new UnsupportedExe(failMsg);
    
    auto actual = file.readBytes!size();
    if(actual != expected)
        throw new UnsupportedExe(failMsg);
}

/// Information on Windows exe format is here:
/// http://en.wikibooks.org/wiki/X86_Disassembly/Windows_Executable_Files
///
/// Returns false if Large Address Aware flag was already set.
bool enableLargeAddressAware(string filename)
{
    enum peHeaderOffsetOffset = 60; // The offset to the location which contains the PE header's location
    enum targetByteOffset = 22; // Offset into the PE header for the byte with the Large Address Aware flag
    enum laaBit = 0b0010_0000;
    ubyte[2] exeMagic = ['M','Z'];
    ubyte[4] peMagic  = ['P','E',0,0];

    if(!filename.toLower().endsWith(".exe"))
        throw new UnsupportedExe("Only .exe files supported.");
    
    auto file = new File(filename, FileMode.In | FileMode.Out);
    scope(exit) file.close();
    
    // Seek to PE header
    file.verifyMagic(exeMagic);
    file.seekSet(peHeaderOffsetOffset);
    auto peHeaderOffset = file.readULong();
    file.seekSet(peHeaderOffset);
    file.verifyMagic(peMagic);
    
    // Seek to target byte
    file.seekSet(peHeaderOffset + targetByteOffset);
    
    // Set Large Address Aware bit
    ubyte data = file.readByte();
    if(data & laaBit)
        return false;
    data |= laaBit;
    file.seekSet(peHeaderOffset + targetByteOffset);
    file.write(data);
    
    return true;
}

int main(string[] args)
{
    if(args.length != 2)
    {
        writeln("largeaddr: Enables the Large Address Aware bit on a Windows exe");
        writeln("Usage: largeaddr someapp.exe");
        return 1;
    }
    
    try
    {
        if(!enableLargeAddressAware(args[1]))
            writeln("Note: Large Address Aware flag was already set.");
    }
    catch(UnsupportedExe e)
    {
        stderr.writeln("largeaddr: Error: ", e.msg);
        return 1;
    }
    
    return 0;
}
