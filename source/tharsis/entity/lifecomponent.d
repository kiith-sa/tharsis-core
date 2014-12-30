//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Builtin component that specifies if an entity is 'alive'.
module tharsis.entity.lifecomponent;


/** Builtin component that specifies if an entity is 'alive' or not.
 *
 * Entities that are not alive will not be carried over to future state.
 */
struct LifeComponent
{
    /// Component type ID of LifeComponent. Builtin components have the lowest IDs.
    enum ushort ComponentTypeID = 1;

    /// True if the component is alive, false otherwise.
    bool alive;

    /** Minimum number of LifeComponents to preallocate.
     *
     * 32k is a lot, but they only take 1 byte and are used by every entity.
     */
    enum minPrealloc = 32768;

    /// Minimum number of LifeComponents to preallocate per entity.
    enum minPreallocPerEntity = 1.0;
}



