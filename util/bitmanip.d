//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.util.bitmanip;


/// Count the number of bits set in a 64bit value.
static size_t countBitsSet(const ulong mask) @safe pure nothrow
{
    size_t result = 0;
    foreach(b; 0 .. 64)
    {
        result += (mask & (1 << b)) ? 1 : 0;
    }
    return result;
}

