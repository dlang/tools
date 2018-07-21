module attributes;

enum betterc;

@betterc @safe @("foo") unittest
{
    assert(1 == 1);
}

@safe @("foo") unittest
{
    assert(2 == 2);
}

///
@("foo") unittest
{
    assert(3 == 3);
}

@("foo") @betterc unittest
{
    assert(4 == 4);
}

@("betterc") @([1, 2, 3]) unittest
{
    assert(5 == 5);
}

@nogc @("foo", "betterc", "bar") @safe unittest
{
    assert(6 == 6);
}

@nogc @("foo", "better", "bar") @safe unittest
{
    assert(7 == 7);
}

@("betterd") unittest
{
    assert(8 == 8);
}
