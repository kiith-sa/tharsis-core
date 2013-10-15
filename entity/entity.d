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
    /// A bitmask specifying which components the entity consists of.
    /// 
    /// Every component type has a ComponentTypeID between 0 and 63 that 
    /// specifies which bit represents that component. If that bit is 1,
    /// the entity contains a component of that type. If it is 0, the entity
    /// does not contain a component of that type.
    ulong components_;

    /// Unique identifier of this entity.
    EntityID id_;

public:
    /// Get the ID of the entity.
    @property EntityID id() const pure nothrow @safe
    {
        return id_;
    }

package:
    /// No default-construction.
    @disable this();

    /// Create an entity with specified ID.
    this(const uint id) pure nothrow @safe
    {
        id_.id_ = id;
    }

    /// Get a mask describing which components the entity contains.
    @property ulong componentMask() const pure nothrow @safe 
    {
        return components_;
    }

    /// Does the entity contain all components specified by given mask?
    bool matchComponents(const ulong mask) const pure nothrow @safe 
    {
        return (mask & components_) == mask;
    }
}
