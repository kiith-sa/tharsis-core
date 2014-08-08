//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Hacks to force D to acknowledge that a function is e.g. @safe or nothrow.
module tharsis.util.qualifierhacks;

import std.string;
import std.traits;


/// Assume a variable is not used by more than one thread at the moment.
///
/// Used to cast away shared() when proper synchronization is used to guarantee
/// that only the current thread can access a variable.
ref T assumeUnshared(T)(ref shared(T) rhs)
{
    return *(cast(T*)&rhs);
}
