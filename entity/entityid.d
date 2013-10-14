//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Unique identifier for an entity.
module tharsis.entity.entityid;

import std.conv;

/// Unique identifier of an Entity.
struct EntityID 
{
package:
    /// The identifier value.
    uint id_; 

public:
    /// Equality comparison with another ID.
    bool opEquals(EntityID rhs) const pure nothrow @safe
    {
        return id_ == rhs.id_;
    }

    /// Comparison for sorting.
    long opCmp(EntityID rhs) const pure nothrow @safe
    {
        return cast(long)id_ - cast(long)rhs.id_;
    }

    /// String representation for debugging.
    string toString() const @trusted
    {
        return to!string(id_);
    }
}
