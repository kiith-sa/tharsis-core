//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// A range used to iterate over entities in EntityManager.
module tharsis.entity.entityrange;


import std.algorithm;
import std.array;
import std.exception: assumeWontThrow;
import std.stdio;
import std.string;
import std.typetuple;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitypolicy;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.lifecomponent;
import tharsis.entity.processtypeinfo;
import tharsis.util.mallocarray;


/// Used to provide direct access to entity components to process() methods.
///
//  Always used as a part of EntityRange.
struct EntityAccess(EntityManager)
{
package:
    /// Index of the past entity we're currently reading.
    ///
    /// Updated by EntityRange.
    size_t pastEntityIndex_ = 0;

    // Hack to allow process type info to figure out that an EntityAccess argument is
    // not a component argument.
    enum isEntityAccess_ = true;

private:
    /// Past entities in the entity manager.
    ///
    /// Past entities that are not alive are ignored.
    immutable(Entity[]) pastEntities_;

    /// Stores past components of all entities.
    immutable(EntityManager.ComponentState)* pastComponents_;

    /// Provides access to component type info.
    AbstractComponentTypeManager componentTypeManager_;

    /// No default construction or copying.
    @disable this();
    @disable this(this);

public:
    /// Access a past (non-multi) component in _any_ past entity.
    ///
    /// This is a relatively slow way to access components, but allows to access
    /// components of any entity. Should only be used when necessary.
    ///
    /// Params: Component = Type of component to access.
    ///         entity    = ID of the entity to access. Must be an ID of an existing
    ///                     past entity.
    ///
    /// Returns: Pointer to the past component if the entity contains such a component;
    ///          NULL otherwise.
    immutable(Component)* pastComponent(Component)(const EntityID entity) nothrow const
        if(!isMultiComponent!Component)
    {
        auto raw = rawPastComponent(Component.ComponentTypeID, entity);
        return raw.isNull ? null : cast(immutable(Component)*)raw.componentData.ptr;
    }

    /// Access a past (non-multi) component in _any_ past entity as raw data.
    ///
    /// Params: typeID = Type ID of component to access. Must be an ID of a registered
    ///                  component type.
    ///         entity = ID of the entity to access. Must be an ID of an existing past
    ///                  entity.
    ///
    /// Returns: A RawComponent representation of the past component if the entity
    ///          contains such a component; NULL RawComponent otherwise.
    ImmutableRawComponent rawPastComponent(const ushort typeID, const EntityID entity)
        nothrow const
    {
        assert(!componentTypeManager_.componentTypeInfo[typeID].isMulti,
               "rawPastComponent can't access components of MultiComponent types");

        // Get the component with type typeID of past entity at index index.
        static auto componentOfEntity(ref const(EntityAccess) self, const ushort typeID,
                                      const size_t index) nothrow
        { with(self) {
            auto pastComponents  = &((*pastComponents_)[typeID]);
            const componentCount = pastComponents.counts[index];
            if(0 == componentCount)
            {
                return ImmutableRawComponent(nullComponentTypeID, null);
            }

            const offset = pastComponents.offsets[index];
            assert(offset != size_t.max, "Offset not set");

            auto raw           = pastComponents.buffer.committedComponentSpace;
            auto componentSize = componentTypeManager_.componentTypeInfo[typeID].size;
            auto byteOffset    = offset * componentSize;
            auto componentData = raw[byteOffset .. byteOffset + componentSize];
            return ImmutableRawComponent(typeID, componentData);
        } }

        // Fast path when accessing a component in the current past entity.
        if(currentEntity().id == entity)
        {
            return componentOfEntity(this, typeID, pastEntityIndex_);
        }

        // If accessing a component in another past entity, binary search to find the
        // entity with matching ID (entities are sorted by ID).
        auto slice = pastEntities_[];
        while(!slice.empty)
        {
            const size_t index = slice.length / 2;
            const EntityID mid = slice[index].id;
            if(mid > entity)       { slice = slice[0 .. index]; }
            else if (mid < entity) { slice = slice[index + 1 .. $]; }
            else                   { return componentOfEntity(this, typeID, index); }
        }

        // If this happens, the user passed an invalid entity ID or we have a bug.
        assert(false, "Couldn't find an entity with specified ID");
    }

    /// Get the entity ID of the entity currently being processed.
    Entity currentEntity() @safe pure nothrow const
    {
        return pastEntities_[pastEntityIndex_];
    }

package:
    /// Construct an EntityAccess for entities of specified entity manager.
    this(EntityManager entityManager) @safe pure nothrow
    {
        pastEntities_         = entityManager.past_.entities;
        pastComponents_       = &entityManager.past_.components;
        componentTypeManager_ = entityManager.componentTypeManager_;
    }
}

package:

/// A range used to iterate over entities and their components in EntityManager.
///
/// Used when executing process Process to read past entities/components and to provide
/// space for future components. Iterates over _all_ past entities; matchComponents()
/// determines if the current entity has components required by any process() method.
struct EntityRange(EntityManager, Process)
{
package:
    alias Policy         = EntityManager.EntityPolicy;
    /// Data type used to store component counts (16 bit uint by default).
    alias ComponentCount = EntityManager.ComponentCount;
    /// Past component types read by _all_ process() methods of Process.
    alias InComponents   = AllPastComponentTypes!Process;

private:
    /// Stores the slice and index for past entities.
    ///
    /// Separate from EntityRange - EntityAccess can be passed to process() methods to
    /// provide direct access to the past entity and its components. Still, EntityRange
    /// directly updates the past entity index inside.
    EntityAccess!EntityManager entityAccess_;

    /// True if the Process does not write to any future component. Usually such
    /// processes only read past components and produce some kind of output.
    enum noFuture = !hasFutureComponent!Process;

    /// Indices to components of current entity in past component buffers. Only the
    /// indices of iterated component types are used.
    size_t[maxComponentTypes!Policy] componentOffsets_;

    /// Index of the future entity we're currently writing to.
    size_t futureEntityIndex_ = 0;

    static if(!noFuture)
    {

    /// Future component written by the process (if any).
    alias FutureComponent = Process.FutureComponent;

    /// Number of future components (of type Process.FutureComponent) written to the
    /// current future entity.
    ///
    /// Ease bug detection with a ridiculous value.
    ComponentCount futureComponentCount_ = ComponentCount.max;

    /// Index of the first future component  for the current entity.
    ///
    /// Used to update ComponentTypeState.offsets .
    uint futureComponentOffset_ = 0;

    /// Buffer and component count for future components written by Process.
    ///
    /// We can't keep a typed slice as the internal buffer may get reallocated; so we
    /// cast on every future component access.
    EntityManager.ComponentTypeState* futureComponents_;

    }

    /// Future entities in the entity manager.
    ///
    /// Used to check if the current past and future entity is the same.
    const(Entity[]) futureEntities_;

    /// All processed component types.
    ///
    /// NoDuplicates! is used to avoid having two elements for the same type if the
    /// process reads a builtin component type.
    alias NoDuplicates!(TypeTuple!(InComponents, BuiltinComponents))
        ProcessedComponents;

    /// (CTFE) Get name of component buffer for specified component type.
    static string bufferName(C)() @trusted
    {
        return "buffer%s_".format(C.ComponentTypeID);
    }

    /// (CTFE) Get name of component count buffer for specified component type.
    static string countsName(ushort ID)() @trusted
    {
        return "counts%s_".format(ID);
    }

    /// (CTFE) For each processed past component type, generate 2 data members:
    /// component buffer and component count buffer.
    static string pastComponentBuffers()
    {
        string[] parts;
        foreach(index, Component; ProcessedComponents)
        {
            parts ~= q{
            immutable(ProcessedComponents[%s][]) %s;
            immutable(MallocArray!ComponentCount*) %s;
            }.format(index, bufferName!Component,
                     countsName!(Component.ComponentTypeID));
        }
        return parts.join("\n");
    }

    /// Mixin slices to access past components, and pointers to component count buffers
    /// to read the number of components of a type per entity.
    ///
    /// These are typed slices to the untyped buffers in the ComponentBuffer struct of
    /// each component type. Past components can also be accessed through
    /// EntityAccess.pastComponents_; these slices are a performance optimization.
    mixin(pastComponentBuffers());

    /// No default construction or copying.
    @disable this();
    @disable this(this);

package:
    /// Construct an EntityRange to iterate over past entities of passed entity manager.
    this(EntityManager entityManager)
    {
        entityAccess_ = EntityAccess!EntityManager(entityManager);
        futureEntities_ = entityManager.future_.entities;

        immutable(EntityManager.ComponentState)* pastComponents =
            &entityManager.past_.components;
        // Init component/component count buffers for processed past component types.
        foreach(index, Component; ProcessedComponents)
        {
            enum id  = Component.ComponentTypeID;
            // Untyped component buffer to cast to a typed slice.
            auto raw = (*pastComponents)[id].buffer.committedComponentSpace;

            mixin(q{
            %s = cast(immutable(ProcessedComponents[%s][]))raw;
            %s = &(*pastComponents)[id].counts;
            }.format(bufferName!Component, index, countsName!id));
        }

        static if(!noFuture)
        {
            enum futureID = FutureComponent.ComponentTypeID;
            futureComponents_ = &entityManager.future_.components[futureID];
        }

        // Skip dead past entities at the beginning, if any, so front() points to an
        // alive entity (unless we're empty)
        skipDeadEntities();
    }

    /// Get the current past entity.
    Entity front() @safe pure nothrow const
    {
        return entityAccess_.currentEntity;
    }

    /// Get the EntityAccess data member to pass it to a process() method.
    ref EntityAccess!EntityManager entityAccess() @safe pure nothrow
    {
        return entityAccess_;
    }

    /// True if we've processed all alive past entities.
    bool empty() @safe pure nothrow
    {
        // Only live entities are in futureEntities; if we're at the end, the rest of
        // past entities are dead and we don't need to process them.
        return futureEntityIndex_ >= futureEntities_.length;
    }

    /// Move to the next alive past entity (end the range if no alive entities left).
    ///
    /// Also moves to the next future entity (which is the same as the next alive past
    /// entity) and moves to the components of the next entity.
    void popFront() @trusted nothrow
    {
        assert(!empty, "Trying to advance an empty entity range");
        const past   = front().id;
        const future = futureEntities_[futureEntityIndex_].id;
        assert(past == future,
               "The past (%s) and future (%s) entity is not the same. Maybe we forgot "
               "to skip a dead past entity, or we copied a dead entity into future "
               "entities, or we inserted a new entity elsewhere than the end of future "
               "entities.".format(past, future).assumeWontThrow);
        assert(pastComponent!LifeComponent().alive,
               "Current entity is dead. Likely a bug when calling skipDeadEntities?");

        nextFutureEntity();
        nextPastEntity();

        skipDeadEntities();
    }

    /// Access a past (non-multi) component in the current entity.
    ///
    /// Params: Component = Type of component to access.
    ///
    /// Returns: An immutable reference to the past component.
    ref immutable(Component) pastComponent(Component)() @safe nothrow const
        if(!isMultiComponent!Component)
    {
        enum id = Component.ComponentTypeID;
        mixin(q{
        return %s[componentOffsets_[id]];
        }.format(bufferName!Component));
    }

    /// Access past multi components of one type in the current entity.
    ///
    /// Params: Component = Type of components to access.
    ///
    /// Returns: An immutable slice to the past components.
    immutable(Component)[] pastComponent(Component)() @safe nothrow const
        if(isMultiComponent!Component)
    {
        enum id = Component.ComponentTypeID;
        const offset = componentOffsets_[id];

        mixin(q{
        // Get the number of components in the current past entity.
        const componentCount = (*%s)[entityAccess_.pastEntityIndex_];
        // The first component in the current entity is at 'offset'.
        return %s[offset .. offset + componentCount];
        }.format(countsName!id, bufferName!Component));
    }

    // Only access the future component if the process writes any.
    static if(!noFuture)
    {

    // Non-multi future component.
    static if(!isMultiComponent!FutureComponent)
    {

    /// Get a reference to write the future component for the current entity 
    /// (process() may still decide not to write it, though).
    ref FutureComponent futureComponent() @trusted nothrow
    {
        enum neededSpace = maxComponentsPerEntity!(FutureComponent);
        // Ensures the needed space is allocated.
        ubyte[] unused =
            futureComponents_.buffer.forceUncommittedComponentSpace(neededSpace);
        return *cast(FutureComponent*)(unused.ptr);
    }

    }
    // Multi future component.
    else
    {

    /// Get a slice to write future multicomponents for the current entity to. The slice
    /// is at least FutureComponent.maxComponentsPerEntity long.
    FutureComponent[] futureComponent() @trusted nothrow
    {
        enum maxComponents = maxComponentsPerEntity!(FutureComponent);
        // Ensures the needed space is allocated.
        ubyte[] unused =
            futureComponents_.buffer.forceUncommittedComponentSpace(maxComponents);
        return (cast(FutureComponent*)(unused.ptr))[0 .. maxComponents];
    }

    }

    /// Specify the number of future components written for the current entity.
    ///
    /// May be called more than once while processing an entity; the last call must pass
    /// the number of components actually written.
    ///
    /// Params: count = Number of components written. Must be 0 or 1 for non-multi
    ///                 components.
    void setFutureComponentCount(const ComponentCount count) @safe pure nothrow
    {
        assert(isMultiComponent!FutureComponent || count <= 1,
               "Component count for a non-multi component can be at most 1");
        futureComponentCount_ = count;
    }

    }

    /// Determine if the current entity contains specified component types.
    bool matchComponents(ComponentTypeIDs...)() @trusted
    {
        // Type IDs of processed component types.
        enum processedIDs = componentIDs!ProcessedComponents;
        // Type IDs of component types we're matching (must be a subset of processedIDs)
        enum sortedIDs    = std.algorithm.sort([ComponentTypeIDs]);
        static assert(sortedIDs.setDifference(processedIDs).empty,
                      "One or more matched component types are not processed by this "
                      "EntityRange.");

        static string matchCode()
        {
            // If the component count for any required component type is 0, the product
            // of multiplying them all is 0. If all are at least 1, the result is true.
            string[] parts;
            foreach(id; ComponentTypeIDs)
            {
                // Component count for this component type will be a member of the
                // product.
                parts ~= q{(*%s)[entityAccess_.pastEntityIndex_]}.format(countsName!id);
            }
            return parts.join(" * ");
        }

        mixin(q{const result = cast(bool)(%s);}.format(matchCode()));
        return result;
    }

private:
    /// Skip (past) dead entities until an alive entity is reached.
    void skipDeadEntities() @safe nothrow
    {
        while(!empty && !pastComponent!LifeComponent().alive)
        {
            nextPastEntity();
        }
    }

    /// Move to the next past entity and its components.
    void nextPastEntity() @safe nothrow
    {
        // Generate code for every processed component type to move past the components
        // in this entity.
        foreach(C; ProcessedComponents)
        {
            enum id = C.ComponentTypeID;
            mixin(q{
            // Increase offset for this component type by the number of components in
            // the current past entity.
            componentOffsets_[id] += (*%s)[entityAccess_.pastEntityIndex_];
            }.format(countsName!id));
        }
        ++entityAccess_.pastEntityIndex_;
    }

    /// Move to the next future entity.
    ///
    /// Also definitively commits the future components for the current entity.
    void nextFutureEntity() @safe pure nothrow
    {
        static if(!noFuture)
        {
            enum id = FutureComponent.ComponentTypeID;
            with(futureComponents_)
            {
                buffer.commitComponents(futureComponentCount_);
                counts[futureEntityIndex_]  = futureComponentCount_;
                offsets[futureEntityIndex_] = futureComponentOffset_;
            }
            futureComponentOffset_ += futureComponentCount_;
            // Ease bug detection by setting to an absurd value.
            futureComponentCount_ = ComponentCount.max;
        }
        ++futureEntityIndex_;
    }

    /// A debug method to print the component counts of processed component types in the
    /// current entity.
    void printComponentCounts()
    {
        string[] parts;
        foreach(C; ProcessedComponents)
        {
            enum id = C.ComponentTypeID;
            mixin(q{
            const count = (*%s)[entityAccess_.pastEntityIndex_];
            }.format(countsName!id));
            parts ~= "%s: %s".format(id, count);
        }
        return writefln("Component counts (typeid: count):\n%s", parts.join(","));
    }
}
