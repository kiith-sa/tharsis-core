//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Data structures storing game state (components and entities) in EntityManager.
module tharsis.entity.gamestate;


import tharsis.entity.componentbuffer;
import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.entitypolicy;
import tharsis.prof;
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
    void growEntityCount(const size_t count, Profiler profiler)
    {
        auto zone = Zone(profiler, "growEntityCount");
        assert(enabled_, "This ComponentTypeState is not enabled");
        {
            counts.reserve(count);
            offsets.reserve(count);
        }
        const oldSize = counts.length;

        counts.growUninitialized(count);
        offsets.growUninitialized(count);
        // In debug mode, pre-initialize counts/offsets to help detect bugs.
        // In release mode, counts/offsets will be uninitialized (to be overwritten as the
        // process runs)
        //
        // With ~70 component types, this takes ~4ms per frame so it's not viable in
        // release mode.
        debug
        {
            auto zoneInit = Zone(profiler, "init");
            counts[oldSize .. $] = cast(ComponentCount)0;
            (cast(ubyte[])offsets[oldSize .. $])[] = ubyte.max;
        }
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
    void growEntityCount(const size_t count, Profiler profiler)
    {
        foreach(ref data; this) if(data.enabled)
        {
            data.growEntityCount(count, profiler);
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

    /** Number of entities *before* adding new entities for the current frame.
     *
     * For past state, this is the number of entities from the last frame.
     * For future state, this is the number of *surviving* entities that didn't die during
     * the last frame.
     */
    size_t entityCountNoAdded;


    /* TODO: May add a structure to access entities by entityID to speed up direct
     * component access with EntityAccess (currently using binary search). Could use some
     * hash map, or a multi-level bucket-sorted structure (?) (E.g. 65536 buckets for the
     * first 16 bits of the entity ID, and arrays/slices in the buckets)
     *
     * Would have to be updated with the entity array between frames.
     */


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
    /** Update game state related values in entity manager diagnostics.
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
                const componentBytes = buffer.componentBytes;
                const countBytes     = ComponentCount.sizeof;
                const offsetBytes    = uint.sizeof;

                name                = compTypeInfo[typeID].name;
                pastComponentCount  = buffer.committedComponents;
                pastMemoryAllocated = buffer.allocatedSize * componentBytes +
                                      counts.capacity * countBytes +
                                      offsets.capacity * offsetBytes;
                pastMemoryUsed      = pastComponentCount * componentBytes +
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
    void copyLiveEntitiesToFuture(ref GameState future)
        @system pure nothrow const
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
        future.entities = future.entities[0 .. aliveEntities];
    }

    /** Add specified number of new entities, without initializing them or their components.
     *
     * Also reserves space for per-entity component counts/offsets for each component type.
     */
    void addNewEntitiesNoInit(size_t addedCount, Profiler profiler) @system nothrow
    {
        auto zone = Zone(profiler, "GameState.addNewEntitiesNoInit()");
        entityCountNoAdded = entities.length;
        entities.assumeSafeAppend();
        {
            auto zoneEntitiesRealloc = Zone(profiler, "entities potential realloc");
            entities.length = entities.length + addedCount;
        }
        components.growEntityCount(entities.length, profiler);
    }

    /// Get entities added during this (starting) game update.
    Entity[] addedEntities() @safe pure nothrow @nogc
    {
        return entities[entityCountNoAdded .. $];
    }
}

import std.typecons;
import tharsis.entity.entityprototype;

/** Add newly created entities to past and future state for a beginning frame.
 *
 * Executed by EntityManager between frames in executeFrame(). Entities are added both to
 * past and future state of the next frame. Processes running during the next frame will
 * decide which entities survive beyond the next frame.
 *
 * Params:
 *
 * prototypes       = Prototypes and entity IDs to initialize the new entities with.
 * componentTypeMgr = Access to component type info.
 * newPast          = Past state for the new frame.
 * newFuture        = Future state for the new frame.
 */
void initNewEntities(Policy)
    (ref MallocArray!(Tuple!(immutable(EntityPrototype)*, EntityID)) prototypes,
     const(AbstractComponentTypeManager) componentTypeMgr,
     ref GameState!Policy newPast, ref GameState!Policy newFuture)
    @trusted nothrow
{
    // We're adding entities created during the previous frame; the next frame will see
    // their components as past state.
    ComponentTypeState!Policy[] target = newPast.components.self_[];
    // Past entities to add the newly created entities to.
    Entity[] targetPast = newPast.addedEntities;
    // Future entities to add the newly created entities to. (They need to be added for
    // processes to run; processes running during the next frame will then decide whether
    // or not they will continue to live).
    Entity[] targetFuture = newFuture.addedEntities;

    const(ComponentTypeInfo)[] compTypeInfo = componentTypeMgr.componentTypeInfo;
    foreach(index, pair; prototypes)
    {
        immutable(EntityPrototype)* prototype = pair[0];

        // Component counts of each component type for this entity.
        Policy.ComponentCount[maxComponentTypes!Policy] componentCounts;

        // Copy components from the prototype to component buffers.
        foreach(const rawComponent; prototype.constComponentRange(compTypeInfo))
        {
            // Copies and commits the component.
            target[rawComponent.typeID].buffer.addComponent(rawComponent);
            ++componentCounts[rawComponent.typeID];
        }

        import tharsis.entity.lifecomponent;
        // Add a (mandatory) LifeComponent.
        enum lifeID = LifeComponent.ComponentTypeID;
        auto life   = LifeComponent(true);
        auto source = RawComponent(lifeID, cast(ubyte[])((&life)[0 .. 1]));
        target[lifeID].buffer.addComponent(source);
        ++componentCounts[lifeID];

        // Add the new entity to past/future entities.
        const EntityID entityID = pair[1];
        targetPast[index] = targetFuture[index] = Entity(entityID);

        // Set the component counts/offsets for this entity.
        foreach(typeID, count; componentCounts)
        {
            if(!target[typeID].enabled) { continue; }
            const globalIndex = newPast.entityCountNoAdded + index;
            const offset = globalIndex == 0
                         ? 0 : target[typeID].offsets[globalIndex - 1] + count;
            target[typeID].counts[globalIndex]  = count;
            target[typeID].offsets[globalIndex] = cast(uint)offset;
        }
    }
}
