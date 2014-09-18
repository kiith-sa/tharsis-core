//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Data structures storing game state (components and entities) in EntityManager.
module tharsis.entity.gamestate;


import tharsis.entity.componentbuffer;
import tharsis.entity.componenttypeinfo;
import tharsis.entity.entity;
import tharsis.entity.entitypolicy;
import tharsis.util.mallocarray;
import tharsis.util.noncopyable;


package:

/** All state belonging to one component type.
 *
 * Stores the components and component counts for each entity.
 *
 * Future versions of both the components and component counts are cleared when the frame
 * begins, then added over the course of a frame.
 */
struct ComponentTypeState(Policy)
{
    mixin(NonCopyable);
    alias ComponentCount = Policy.ComponentCount;

public:
    /// Stores components as raw bytes.
    ComponentBuffer!Policy buffer;

    /** Component counts for every entity (counts[i] is the number of components for the
     * entity at entities[i] in entity storage).
     */
    MallocArray!ComponentCount counts;

    /** Offsets of the first component for every entity (offsets[i] is the index of the
     * first component for entity at entities[i] in entity storage).
     *
     * For entities that have zero components of this type, the offset is uint.max (absurd
     * value to detect bugs).
     *
     * Allows fast access to components of any past entity (if we know its index); this
     * enables direct component access through EntityAccess.
     */
    MallocArray!uint offsets;

private:
    /// True if this ComponentTypeState is used by an existing component type.
    bool enabled_;

public:
    @disable this();

    /// Destroy the ComponentTypeState.
    ~this()
    {
        // Not necessary, but useful to catch bugs.
        if(enabled_) { reset(); }
    }

    /** Enable the ComponentTypeState.
     *
     * Called when an existing component type will use this ComponentTypeState.
     *
     * Params: typeInfo = Type information about the type of components stored in this
     *                    ComponentTypeState.
     */
    void enable(ref const(ComponentTypeInfo) typeInfo) @safe pure nothrow
    {
        assert(!enabled_, "Trying to enable ComponentTypeState that's already enabled. "
                          " Maybe 2 component types use the same type ID?");

        buffer.enable(typeInfo.id, typeInfo.size);
        enabled_ = true;
    }

    /// Is there a component type using this ComponentTypeState?
    bool enabled() @safe pure nothrow const @nogc { return enabled_; }

private:
    /** Grow the number of entities to store component counts for.
     *
     * Can only be used to _increase_ the number of entities. Component counts for the new
     * entities are set to 0. Used by EntityManager e.g. after determining the number of
     * future entities and before adding newly created entities.
     *
     * Params: count = New entity count. Must be greater than the current entity count
     *                 (set by a previous call to reset or growEntityCount).
     */
    void growEntityCount(const size_t count)
    {
        assert(enabled_, "This ComponentTypeState is not enabled");
        counts.reserve(count);
        offsets.reserve(count);
        const oldSize = counts.length;
        counts.growUninitialized(count);
        offsets.growUninitialized(count);
        counts[oldSize .. $]  = cast(ComponentCount)0;
        offsets[oldSize .. $] = uint.max;
    }

    /** Reset the buffers, clearing them.
     *
     * Sets the entity count to 0.
     */
    void reset() @safe pure nothrow
    {
        assert(enabled_, "This ComponentTypeState is not enabled");
        buffer.reset();
        counts.clear();
        offsets.clear();
    }
}

/** Stores components of all entities (either past or future).
 *
 * Also stores component counts of every component type for every entity.
 */
struct ComponentState(Policy)
{
    mixin(NonCopyable);
public:
    /** Stores component/component count buffers for all component types at indices set by
     * the ComponentTypeID members of the component types.
     */
    ComponentTypeState!Policy[maxComponentTypes!Policy] self_;

    /// Access the component type state array directly.
    alias self_ this;

    @disable this();

private:
    /** Clear the buffers.
     *
     * Used to clear future component buffers when starting a frame.
     */
    void resetBuffers()
    {
        foreach(ref data; this) if(data.enabled) { data.reset(); }
    }

    /** Inform the component counts buffers about increased (or equal) entity count.
     *
     * Called between frames when entities are added.
     */
    void growEntityCount(const size_t count)
    {
        foreach(ref data; this) if(data.enabled)
        {
            data.growEntityCount(count);
        }
    }
}

/** Stores all game state (entities and components).
 *
 * EntityManager has two instances of GameState; past and future.
 */
struct GameState(Policy)
{
    /* TODO: An alternative implementation of GameState storage to try:
     *
     * For every component type, there is a buffer of entityID-componentIdx pairs.
     *
     * A pair says 'this entity has this component'. If an entity has more than 1
     * component, have multiple pairs. (Or, MultiComponents, use triplets instead of
     * pairs, with the last member of the triplet being component count)
     *
     * When running a process, we run only through buffers of the relevant component
     * types. Meaning we don't run over _all_ entities. Especially relevant for systems
     * processing unusual components.
     *
     * Implement this and compare speed. Perhaps even have 2 switchable implementations.
     */
    /// Stores components of all entities.
    ComponentState!Policy components;

    //TODO entities should be manually allocated.
    /**
     * All existing entities (either past or future).
     *
     * Ordered by entity ID. This is necessary to enable direct component access through
     * EntityAccess.
     *
     * The entire length of this array is used; it doesn't have a unused part at the end.
     */
    Entity[] entities;

    /* TODO: May add a structure to access entities by entityID to speed up direct
     * component access with EntityAccess (currently using binary search). Could use some
     * hash map, or a multi-level bucket-sorted structure (?) (E.g. 65536 buckets for the
     * first 16 bits of the entity ID, and arrays/slices in the buckets)
     *
     * Would have to be updated with the entity array between frames.
     */


    import tharsis.entity.componenttypemanager;
    /** Preallocate space in component buffers.
     *
     * Part of the code executed between frames in EntityManager.executeFrame().
     *
     * Used to prealloc space for future components to minimize allocations during update.
     *
     * Params: allocMult        = Allocation size multiplier.
     *         componentTypeMgr = Component type manager (for component type info).
     */
    void preallocateComponents(float allocMult,
                               const(AbstractComponentTypeManager) componentTypeMgr)
        @safe nothrow
    {
        // Prealloc space for components based on hints in Policy and component type info.
        const entityCount    = entities.length;
        const minAllEntities = cast(size_t)(Policy.minComponentPerEntityPrealloc * entityCount);
        enum baseMinimum     = Policy.minComponentPrealloc;

        foreach(ref info; componentTypeMgr.componentTypeInfo) if(!info.isNull)
        {
            import std.algorithm;
            // Component type specific minimums.
            const minimum             = max(baseMinimum, info.minPrealloc);
            const specificAllEntities = cast(size_t)(info.minPreallocPerEntity * entityCount);
            const allEntities         = max(minAllEntities, specificAllEntities);
            const prealloc            = cast(size_t)(allocMult * max(minimum, allEntities));
            components[info.id].buffer.reserveComponentSpace(prealloc);
        }
    }

    import tharsis.entity.diagnostics;
    /** Update game state related value in entity manager diagnostics.
     *
     * Params:
     *
     * diagnostics      = Diagnostics to update.
     * componentTypeMgr = Component type manager (for component type info).
     */
    void updateDiagnostics(ref EntityManagerDiagnostics!Policy diagnostics,
                           const(AbstractComponentTypeManager) componentTypeMgr)
        @safe pure nothrow const @nogc
    {
        const pastEntityCount = entities.length;
        diagnostics.pastEntityCount = pastEntityCount;

        // Accumulate component type diagnostics.
        const(ComponentTypeInfo)[] compTypeInfo = componentTypeMgr.componentTypeInfo;
        foreach(ushort typeID; 0 .. cast(ushort)compTypeInfo.length)
        {
            if(compTypeInfo[typeID].isNull) { continue; }

            // Get diagnostics for one component type.
            with(components[typeID]) with(diagnostics.componentTypes[typeID])
            {
                name = compTypeInfo[typeID].name;
                foreach(entity; 0 .. pastEntityCount)
                {
                    pastComponentCount += counts[entity];
                }
                const componentBytes = buffer.componentBytes;
                const countBytes     = ComponentCount.sizeof;
                const offsetBytes    = uint.sizeof;

                pastMemoryAllocated = buffer.allocatedSize * componentBytes +
                                      counts.capacity * countBytes +
                                      offsets.capacity * offsetBytes;
                pastMemoryUsed = pastComponentCount * componentBytes +
                                 pastEntityCount * (countBytes + offsetBytes);
            }
        }
    }

    /** Copy the surviving entities from past (this GameState) to future entity buffer.
     *
     * Note that immediately after copied, the future entities will have no components
     * (component buffers in GameState will be reset).
     *
     * Executed between frames in EntityManager.executeFrame().
     *
     * Params: past   = New past, former future state.
     *         future = New future, former past state. future.entities must be exactly
     *                  as long as past.entities. Surviving entities will be copied here.
     *
     * Returns: The number of surviving entities written to futureEntities.
     */
    size_t copyLiveEntitiesToFuture(ref GameState future)
        @trusted pure nothrow const
    {
        future.entities = future.entities[0 .. entities.length];
        // Clear the future (recycled from former past) entities to help detect bugs.
        future.entities[] = Entity.init;

        import tharsis.entity.lifecomponent;
        // Get the past LifeComponents.
        enum lifeID            = LifeComponent.ComponentTypeID;
        auto rawLifeComponents = components[lifeID].buffer.committedComponentSpace;
        auto lifeComponents    = cast(immutable(LifeComponent)[])rawLifeComponents;

        // Copy the alive entities to the future and count them.
        size_t aliveEntities = 0;
        foreach(i, pastEntity; entities) if(lifeComponents[i].alive)
        {
            future.entities[aliveEntities++] = pastEntity;
        }

        future.components.resetBuffers();
        return aliveEntities;
    }

    /** Reserve space for specified number of entities.
     *
     * Also reserves space for per-entity component counts/offsets for each component type.
     */
    void growEntityCountTo(size_t newCount)
    {
        entities.length = newCount;
        components.growEntityCount(newCount);
    }
}
