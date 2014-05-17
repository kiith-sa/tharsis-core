//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// An extension to std.typecons.
module tharsis.util.typecons;

public import std.typecons;

/// A simple wrapper to turn a struct type into a class type.
class Class(Struct)
{
    /// The wrapped struct.
    Struct self_;

    /// Make the class behave as if it was Struct.
    alias self_ this;
}
