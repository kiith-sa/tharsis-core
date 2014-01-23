//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Various array/slice utility functions.
module tharsis.util.array;


import std.array;

/// Return array.front, or if array is empty, return def.
T frontOrIfEmpty(T)(T[] array, T def) 
{ 
    return array.empty ? def : array.front; 
}

/// Return array.front, or if array is empty, return def.
const(T) frontOrIfEmpty(T)(const(T)[] array, const T def)
{ 
    return array.empty ? def : array.front; 
}

/// Return array.back, or if array is empty, return def.
T backOrIfEmpty(T)(T[] array, T def)
{
    return array.empty ? def : array.back;
}

/// Return array.back, or if array is empty, return def.
const(T) backOrIfEmpty(T)(const(T)[] array, const T def)
{
    return array.empty ? def : array.back;
}
