//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Various math utility functions.
module tharsis.util.math;


import std.traits;


/// Align value to the nearest greater multiple of alignTo.
///
/// Params: value   = Value to align.
///         alignTo = The value will be aligned to the nearest greater multiple
///                   of this. Must be greater than 0.
///
/// Returns: The aligned value.
T alignUp(T)(T value, size_t alignTo) @trusted pure nothrow
    if(isIntegral!T)
{
    assert(alignTo > 0, "Can't align to a multiple of 0");
    const long alignToLong = alignTo;
    const base = value + ((value >= 0) ? alignToLong - 1 : 0);
    return cast(T)((base / alignToLong) * alignToLong);
}
unittest 
{
    assert(15.alignUp(16) == 16);
    assert(1.alignUp(16) == 16);
    assert(0.alignUp(16) == 0);
    assert((-1).alignUp(16) == 0);
    assert((-15).alignUp(16) == 0);
    assert((-16).alignUp(16) == -16);
    assert((-17).alignUp(16) == -16);
}

