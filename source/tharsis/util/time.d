//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Time-related utility functions.
module tharsis.util.time;


import std.datetime;
import std.exception;


/// Waits for specified time (in hectonanoseconds) in a hot loop (no thread sleep).
void waitHotLoopHnsecs(ulong hnsecs) @safe nothrow
{
    const start = Clock.currStdTime.assumeWontThrow;
    // On platforms where this throws... we're fucked anyway.
    while(Clock.currStdTime.assumeWontThrow - start < hnsecs) { continue; }
}
