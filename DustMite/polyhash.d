/// Polynomial hash for partial rehashing.
/// http://stackoverflow.com/a/42112687/21501
/// Written by Vladimir Panteleev <vladimir@thecybershadow.net>
/// License: Boost Software License, Version 1.0

module polyhash;

import std.range.primitives;
import std.traits;

struct PolynomialHash(Value)
{
	Value value;   /// The hash value of the hashed string
	size_t length; /// The length of the hashed string

	// Cycle length == 2^^30 for uint, > 2^^46 for ulong
	// TODO: find primitive root modulo 2^^32, if one exists
	enum Value p = Value(269);

	private
	{
		/// Precalculated table for (p^^(2^^i))
		alias Power2s = Value[size_t.sizeof * 8];

		static Power2s genTable()
		{
			Value[size_t.sizeof * 8] result;
			Value v = p;
			foreach (i; 0 .. result.length)
			{
				result[i] = v;
				v *= v;
			}
			return result;
		}

		static if (is(typeof({ enum table = genTable(); })))
			static immutable Power2s power2s = genTable(); // Compute at compile-time
		else
		{
			static immutable Power2s power2s;
			// Compute at run-time (initialization)
			shared static this() { power2s = genTable(); }
		}
	}

	/// Return p^^power (mod q).
	static Value pPower(size_t power)
	{
		Value v = 1;
		foreach (b; 0 .. power2s.length)
			if ((size_t(1) << b) & power)
				v *= power2s[b];
		return v;
	}

	void put(char c)
	{
		value *= p;
		value += Value(c);
		length++;
	}

	void put(in char[] s)
	{
		foreach (c; s)
		{
			value *= p;
			value += Value(c);
		}
		length += s.length;
	}

	void put(ref typeof(this) hash)
	{
		value *= pPower(hash.length);
		value += hash.value;
		length += hash.length;
	}

	static typeof(this) hash(T)(T value)
	if (is(typeof({ typeof(this) result; .put(result, value); })))
	{
		typeof(this) result;
		.put(result, value);
		return result;
	}

	unittest
	{
		assert(hash("").value == 0);
		assert(hash([hash(""), hash("")]).value == 0);

		// "a" + "" + "b" == "ab"
		assert(hash([hash("a"), hash(""), hash("b")]) == hash("ab"));

		// "a" + "bc" == "ab" + "c"
		assert(hash([hash("a"), hash("bc")]) == hash([hash("ab"), hash("c")]));

		// "a" != "b"
		assert(hash("a") != hash("b"));

		// "ab" != "ba"
		assert(hash("ab") != hash("ba"));
		assert(hash([hash("a"), hash("b")]) != hash([hash("b"), hash("a")]));

		// Test overflow
		assert(hash([
			hash("Mary"),
			hash(" "),
			hash("had"),
			hash(" "),
			hash("a"),
			hash(" "),
			hash("little"),
			hash(" "),
			hash("lamb"),
			hash("")
		]) == hash("Mary had a little lamb"));
	}
}

unittest
{
	PolynomialHash!uint uintTest;
	PolynomialHash!ulong ulongTest;
}

unittest
{
	PolynomialHash!(ModQ!(uint, 4294967291)) modQtest;
}

// ****************************************************************************

/// Represents a value and performs calculations in modulo q.
struct ModQ(T, T q)
if (isUnsigned!T)
{
	T value;

	this(T v)
	{
		debug assert(v < q);
		this.value = v;
	}

	bool opEquals(T operand) const
	{
		debug assert(operand < q);
		return value == operand;
	}

	void opOpAssign(string op : "+")(typeof(this) operand)
	{
		T result = this.value;
		result += operand.value;
		if (result >= q || result < this.value || result < operand.value)
			result -= q;
		this.value = result;
	}

	void opOpAssign(string op : "*")(typeof(this) operand)
	{
		this.value = longMul(this.value, operand.value).longDiv(q).remainder;
	}

	T opCast(Q)() const if (is(Q == T)) { return value; }

	// Ensure this type is supported whet it is instantiated,
	// instead of when the operator overloads are
	private static void check() { typeof(this) m; m *= typeof(this)(0); }
}

unittest
{
	alias M = ModQ!(ushort, 100);
	M value;
	value += M(56);
	value += M(78);
	assert(value == 34);
}

unittest
{
	alias M = ModQ!(ushort, 100);
	M value;
	value += M(12);
	value *= M(12);
	assert(value == 44);
}

// ****************************************************************************

private:

import std.traits;

/// Get the smallest built-in unsigned integer type
/// that can store this many bits of data.
template TypeForBits(uint bits)
{
	static if (bits <= 8)
		alias TypeForBits = ubyte;
	else
	static if (bits <= 16)
		alias TypeForBits = ushort;
	else
	static if (bits <= 32)
		alias TypeForBits = uint;
	else
	static if (bits <= 64)
		alias TypeForBits = ulong;
	else
		static assert(false, "No integer type big enough for " ~ bits.stringof ~ " bits");
}

struct LongInt(uint bits, bool signed)
{
	TypeForBits!bits low;
	static if (signed)
		Signed!(TypeForBits!bits) high;
	else
		TypeForBits!bits high;
}

alias LongInt(T) = LongInt!(T.sizeof * 8, isSigned!T);

alias Cent = LongInt!long;
alias UCent = LongInt!ulong;

version (X86)
	version = Intel;
else
version (X86_64)
	version = Intel;

// Hack to work around DMD bug https://issues.dlang.org/show_bug.cgi?id=20677
version (Intel)
	public enum modQSupported = size_t.sizeof == 8;
else
	public enum modQSupported = false;

version (Intel)
{
	version (DigitalMars)
		enum x86RegSizePrefix(T) =
			T.sizeof == 2 ? "" :
			T.sizeof == 4 ? "E" :
			T.sizeof == 8 ? "R" :
			"?"; // force syntax error
	else
	{
		enum x86RegSizePrefix(T) =
			T.sizeof == 2 ? "" :
			T.sizeof == 4 ? "e" :
			T.sizeof == 8 ? "r" :
			"?"; // force syntax error
		enum x86SizeOpSuffix(T) =
			T.sizeof == 2 ? "w" :
			T.sizeof == 4 ? "l" :
			T.sizeof == 8 ? "q" :
			"?"; // force syntax error
	}

	enum x86SignedOpPrefix(T) = isSigned!T ? "i" : "";
}

LongInt!T longMul(T)(T a, T b)
if (is(T : long) && T.sizeof >= 2)
{
	version (Intel)
	{
		version (LDC)
		{
			import ldc.llvmasm;
			auto t = __asmtuple!(T, T)(
				x86SignedOpPrefix!T~`mul`~x86SizeOpSuffix!T~` $3`,
				// Technically, the last one should be "rm", but that generates suboptimal code in many cases
				`={`~x86RegSizePrefix!T~`ax},={`~x86RegSizePrefix!T~`dx},{`~x86RegSizePrefix!T~`ax},r`,
				a, b
			);
			return typeof(return)(t.v[0], t.v[1]);
		}
		else
		version (GNU)
		{
			T low = void, high = void;
			mixin(`
				asm
				{
					"`~x86SignedOpPrefix!T~`mul`~x86SizeOpSuffix!T~` %3"
					: "=a"(low), "=d"(high)
					: "a"(a), "rm"(b);
				}
			`);
			return typeof(return)(low, high);
		}
		else
		{
			T low = void, high = void;
			mixin(`
				asm
				{
					mov `~x86RegSizePrefix!T~`AX, a;
					`~x86SignedOpPrefix!T~`mul b;
					mov low, `~x86RegSizePrefix!T~`AX;
					mov high, `~x86RegSizePrefix!T~`DX;
				}
			`);
			return typeof(return)(low, high);
		}
	}
	else
		static assert(false, "Not implemented on this architecture");
}

version (Intel)
unittest
{
	assert(longMul(1, 1) == LongInt!int(1, 0));
	assert(longMul(1, 2) == LongInt!int(2, 0));
	assert(longMul(0x1_0000, 0x1_0000) == LongInt!int(0, 1));

	assert(longMul(short(1), short(1)) == LongInt!short(1, 0));
	assert(longMul(short(0x100), short(0x100)) == LongInt!short(0, 1));

	assert(longMul(short(1), short(-1)) == LongInt!short(cast(ushort)-1, -1));
	assert(longMul(ushort(1), cast(ushort)-1) == LongInt!ushort(cast(ushort)-1, 0));

	version(X86_64)
	{
		assert(longMul(1L, 1L) == LongInt!long(1, 0));
		assert(longMul(0x1_0000_0000L, 0x1_0000_0000L) == LongInt!long(0, 1));
	}
}

struct DivResult(T) { T quotient, remainder; }

DivResult!T longDiv(T, L)(L a, T b)
if (is(T : long) && T.sizeof >= 2 && is(L == LongInt!T))
{
	version (Intel)
	{
		version (LDC)
		{
			import ldc.llvmasm;
			auto t = __asmtuple!(T, T)(
				x86SignedOpPrefix!T~`div`~x86SizeOpSuffix!T~` $4`,
				// Technically, the last one should be "rm", but that generates suboptimal code in many cases
				`={`~x86RegSizePrefix!T~`ax},={`~x86RegSizePrefix!T~`dx},{`~x86RegSizePrefix!T~`ax},{`~x86RegSizePrefix!T~`dx},r`,
				a.low, a.high, b
			);
			return typeof(return)(t.v[0], t.v[1]);
		}
		else
		version (GNU)
		{
			T low = a.low, high = a.high;
			T quotient = void;
			T remainder = void;
			mixin(`
				asm
				{
					"`~x86SignedOpPrefix!T~`div`~x86SizeOpSuffix!T~` %4"
					: "=a"(quotient), "=d"(remainder)
					: "a"(low), "d"(high), "rm"(b);
				}
			`);
			return typeof(return)(quotient, remainder);
		}
		else
		{
			auto low = a.low;
			auto high = a.high;
			T quotient = void;
			T remainder = void;
			mixin(`
				asm
				{
					mov `~x86RegSizePrefix!T~`AX, low;
					mov `~x86RegSizePrefix!T~`DX, high;
					`~x86SignedOpPrefix!T~`div b;
					mov quotient, `~x86RegSizePrefix!T~`AX;
					mov remainder, `~x86RegSizePrefix!T~`DX;
				}
			`);
			return typeof(return)(quotient, remainder);
		}
	}
	else
		static assert(false, "Not implemented on this architecture");
}

version (Intel)
unittest
{
	assert(longDiv(LongInt!int(1, 0), 1) == DivResult!int(1, 0));
	assert(longDiv(LongInt!int(5, 0), 2) == DivResult!int(2, 1));
	assert(longDiv(LongInt!int(0, 1), 0x1_0000) == DivResult!int(0x1_0000, 0));

	assert(longDiv(LongInt!short(1, 0), short(1)) == DivResult!short(1, 0));
	assert(longDiv(LongInt!short(0, 1), short(0x100)) == DivResult!short(0x100, 0));

	assert(longDiv(LongInt!short(cast(ushort)-1, -1), short(-1)) == DivResult!short(1));
	assert(longDiv(LongInt!ushort(cast(ushort)-1, 0), cast(ushort)-1) == DivResult!ushort(1));

	version(X86_64)
	{
		assert(longDiv(LongInt!long(1, 0), 1L) == DivResult!long(1));
		assert(longDiv(LongInt!long(0, 1), 0x1_0000_0000L) == DivResult!long(0x1_0000_0000));
	}
}
