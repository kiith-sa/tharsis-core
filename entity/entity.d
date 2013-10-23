//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.entity.entity;

import tharsis.entity.entityid;


/// An entity consisting of components.
/// 
/// The entity itself does not store any components; it only has an identifier 
/// and information about what components it consists of.
struct Entity 
{
private:
    /// Unique identifier of this entity.
    EntityID id_;

public:
    /// Get the ID of the entity.
    @property EntityID id() const pure nothrow @safe
    {
        return id_;
    }

package:
    /// Create an entity with specified ID.
    this(const EntityID id) pure nothrow @safe
    {
        id_ = id;
    }
}
