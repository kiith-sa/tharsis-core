//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Unique identifier of an entity.
module tharsis.entity.entityid;

import std.conv;

/// Unique identifier of an Entity.
struct EntityID
{
package:
    // The identifier value.
    uint id_ = uint.max;

public:
    /// Equality comparison with another ID.
    bool opEquals(EntityID rhs) const pure nothrow @safe @nogc
    {
        return id_ == rhs.id_;
    }

    /// Is the ID null? (E.g. unititialized, or returned by a failed operation)
    @property bool isNull() const pure nothrow @safe @nogc
    {
        return id_ == uint.max;
    }

    /// Comparison for sorting.
    long opCmp(EntityID rhs) const pure nothrow @safe @nogc
    {
        return cast(long)id_ - cast(long)rhs.id_;
    }

    /// String representation for debugging.
    string toString() const @trusted
    {
        return to!string(id_);
    }
}
