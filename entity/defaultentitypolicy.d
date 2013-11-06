//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Default policy controlling compile-time parameters to the entity system.
module tharsis.entity.defaultentitypolicy;


import std.traits;

import tharsis.entity.componenttypeinfo;


//XXX if minComponentPerEntityPrealloc is >= 1, specify we never run out of
//    component space during a frame, which allows us to simplify 
//    some componentIterator code (e.g. no branch to check if we've ran out 
//    of space).

/// Default policy controlling compile-time parameters to the entity system.
struct DefaultEntityPolicy
{
    /// Maximum possible component type count.
    ///
    /// ComponentTypeIDs of user-defined component types must be 
    /// >= maxBuiltinComponentTypes and < maxComponentTypes.
    enum maxComponentTypes = 64;

    /// Maximum entities added during one frame.
    enum maxNewEntitiesPerFrame = 4096;

    /// Minimum size of component buffers (in components) for every component 
    /// type to preallocate.
    enum minComponentPrealloc = 1024;

    /// The multiplier to increase allocated size during an emergency reallocation.
    enum reallocMult = 2.5;

    /// Minimum relative size of component buffers (in components) for every 
    /// component type compared to entity count.
    enum minComponentPerEntityPrealloc = 0.05;

    /// Data type used internally for component counts in an entity.
    ///
    /// The maximum number of components of one type in an entity is 
    /// ComponentCount.max. Using data types such as uint or ulong will
    /// increase memory usage.
    alias ushort ComponentCount;
}

/// Check if an entity policy is valid.
template validateEntityPolicy(Policy)
{
    static assert(Policy.maxComponentTypes > maxBuiltinComponentTypes,
                  "maxComponentTypes too low");
    static assert(std.traits.isUnsigned!(Policy.ComponentCount),
                  "ComponentCount must be an unsigned integer type");
    static assert(Policy.reallocMult > 1.0,
                  "reallocMult must be greater than 1");
}
