//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Default policy controlling compile-time parameters to the entity system.
module tharsis.entity.entitypolicy;


import std.traits;

import tharsis.entity.componenttypeinfo;



//TODO if minComponentPerEntityPrealloc is >= 1 specify for MultiComponents that we
//     never run out of component space during a frame, which allows us to simplify some
//     componentIterator code (e.g. no branch to check if we've ran out of space).

/// Default policy controlling compile-time parameters to the entity system.
struct DefaultEntityPolicy
{
    /** Maximum possible number of user-defined component types.
     *
     * ComponentTypeIDs of user-defined component types must be
     * >= maxReservedComponentTypes and < maxReservedComponentTypes + maxUserComponentTypes.
     *
     * If changed, update doc in tharsis/entity/componenttypemanager.d
     */
    enum maxUserComponentTypes = 256;

    /// Maximum entities added during one frame.
    enum maxNewEntitiesPerFrame = 4096;

    /// Min size of component buffers (in components) for every component type to preallocate.
    enum minComponentPrealloc = 1024;

    /// The multiplier to increase allocated size during an emergency reallocation.
    enum reallocMult = 2.5;

    /** Minimum relative size of component buffers (in components) for every component type
     * compared to entity count.
     */
    enum minComponentPerEntityPrealloc = 0.05;

    /** Process names longer than this will be cut to this length for profiling purposes.
     *
     * Tharsis uses internal profiling to balance load of Processes between threads. Using
     * Processes with names longer than this will work but may result in suboptimal
     * performance if two Processes end up being confused after their names are cut.
     *
     * Can be at most 255.
     */
    enum profilerNameCutoff = 128;

    /** Data type used internally for component counts in an entity.
     *
     * The maximum number of components of one type in an entity is ComponentCount.max.
     * Using data types such as uint or ulong will increase memory usage.
     */
    alias ushort ComponentCount;
}

/// Check if an entity policy is valid.
template validateEntityPolicy(Policy)
{
    static assert(std.traits.isUnsigned!(Policy.ComponentCount),
                  "ComponentCount must be an unsigned integer type");
    static assert(Policy.reallocMult > 1.0, "reallocMult must be greater than 1");
    static assert(Policy.profilerNameCutoff <= 255,
                  "profilerNameCutoff must not be more than 255");
}

/** The maximum possible number of component types when using specified entity policy,
 * including builtins, defaults and user defined.
 */
template maxComponentTypes(Policy)
{
    enum maxComponentTypes = maxReservedComponentTypes + Policy.maxUserComponentTypes;
    static assert(maxComponentTypes < ushort.max, "Too many component types");
}
