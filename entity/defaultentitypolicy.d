//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Default policy controlling compile-time parameters to the entity system.
module tharsis.entity.defaultentitypolicy;


import std.traits;

import tharsis.entity.componenttypeinfo;



/// Default policy controlling compile-time parameters to the entity system.
struct DefaultEntityPolicy
{
    /// Maximum possible component type count.
    ///
    /// ComponentTypeIDs of user-defined component types must be 
    /// >= maxBuiltinComponentTypes and < maxComponentTypes.
    enum maxComponentTypes = 64;

    /// Data type used internally for component counts in an entity.
    ///
    /// The maximum number of components of one type in an entity is 
    /// ComponentCount.max. Using data types such as uint or ulong will
    /// increase memory usage.
    alias ushort ComponentCount;
}

/// Check if an entity policy is valid.
template isValidEntityPolicy(Policy)
{
    enum isValidEntityPolicy = 
        Policy.maxComponentTypes > maxBuiltinComponentTypes &&
        isUnsigned!(Policy.ComponentCount);
}
