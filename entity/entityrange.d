//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// A range used to iterate over entities in EntityManager.
module tharsis.entity.entityrange;


import std.algorithm;
import std.stdio;
import std.string;
import std.typetuple;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.entitypolicy;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.lifecomponent;
import tharsis.entity.processtypeinfo;
import tharsis.util.mallocarray;


package:

/// A range used to iterate over entities and their components in EntityManager.
///
/// Used when executing process Process to read past entities and their
/// components and to access space to write future components to. Iterates over
/// _all_ past entities, but matchComponents() can be used to determine if the
/// current entity has components required by a process() method.
struct EntityRange(EntityManager, Process)
{
package:
    alias Policy         = EntityManager.EntityPolicy;
    /// Data type used to store component counts (16 bit uint by default).
    alias ComponentCount = EntityManager.ComponentCount;
    /// Past component types read by _all_ process() methods of Process.
    alias InComponents   = AllPastComponentTypes!Process;

    // Hack to allow process type info to easily figure out that an EntityAccess
    // argument is not a component argument.
    enum isEntityAccess_ = true;

private:
    /// True if the Process does not write to any future component. Usually such
    /// processes only read past components and produce some kind of output.
    enum noFuture = !hasFutureComponent!Process;

    /// Indices to components of current entity in past component buffers. Only
    /// the indices of iterated component types are used.
    size_t[maxComponentTypes!Policy] componentOffsets_;

    // Index of the past entity we're currently reading.
    size_t pastEntityIndex_ = 0;

    /// Index of the future entity we're currently writing to.
    size_t futureEntityIndex_ = 0;

    // Stores past components of all entities.
    //
    // Direct pointers to component buffers of component types processed by the
    // process are also stored as an optimization.
    immutable(EntityManager.ComponentState)* pastComponents_;

    static if(!noFuture)
    {

    /// Future component written by the process (if any).
    alias FutureComponent = Process.FutureComponent;

    /// Number of future components (of type Process.FutureComponent) written to
    /// the current future entity.
    ///
    /// Ease bug detection with a ridiculous value.
    ComponentCount futureComponentCount_ = ComponentCount.max;

    /// Index of the first future component  for the current entity.
    ///
    /// Used to update ComponentTypeState.offsets .
    uint futureComponentOffset_ = 0;

    /// Buffer and component count for future components written by Process.
    ///
    /// We can't keep a typed slice as the internal buffer may get reallocated;
    /// so we cast on every future component access.
    EntityManager.ComponentTypeState* futureComponents_;

    }

    /// Past entities in the entity manager.
    ///
    /// Past entities that are not alive are ignored.
    immutable(Entity[]) pastEntities_;

    /// Future entities in the entity manager.
    ///
    /// Used to check if the current past and future entity is the same.
    const(Entity[]) futureEntities_;

    /// All processed component types.
    ///
    /// NoDuplicates! is used to avoid having two elements for the same type if
    /// the process reads a builtin component type.
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

    /// Mixin slices to access past components, and pointers to component count
    /// buffers to read the number of components of a type per entity.
    ///
    /// These are typed slices of the untyped buffers in the ComponentBuffer 
    /// struct of each component type.
    mixin(pastComponentBuffers());

    /// No default construction or copying.
    @disable this();
    @disable this(this);

public:
    /// Access a past (non-multi) component in _any_ past entity.
    ///
    /// This is a relatively 'slow' way to access components, but it allows to
    /// access components of any entity.
    ///
    /// Params: Component = Type of component to access.
    ///         Entity    = ID of the entity to access.
    ///
    /// Returns: An immutable reference to the past component.
    ref immutable(Component) pastComponent(Component)(const EntityID entity)
        @safe nothrow const
        if(!isMultiComponent!Component)
    {
        enum typeID = Component.ComponentTypeID;
        // Fast path; if we're accessing a component in the current past
        // entity.
        if(currentEntity() == entity)
        {
            return pastComponents_[typeID][pastEntityIndex_];
        }

        // If we're accessing a component in some other past entity, we need
        // to binary search to find the entity with matching ID (entities
        // are sorted by entity ID).
        auto slice = pastEntities_[];
        while(!slice.empty)
        {
            const size_t idx = slice.length / 2;
            const EntityID mid = slice[idx].id;
            if(mid > entity)       { slice = slice[0 .. idx]; }
            else if (mid < entity) { slice = slice[idx + 1 .. $]; }
            else                   { return pastComponents_[typeID][idx]; }
        }

        // If this happens, we either have a bug or the user passed an
        // invalid entity ID.
        assert(false, "Couldn't find the entity with specified ID");
    }

    /// Get the entity ID of the entity currently being processed.
    Entity currentEntity() @safe pure nothrow const { return front(); }

package:
    /// Construct an EntityAccess to iterate over past entities of specified 
    /// entity manager.
    this(EntityManager entityManager)
    {
        pastEntities_   = entityManager.past_.entities;
        futureEntities_ = entityManager.future_.entities;
        pastComponents_ = &entityManager.past_.components;
        // Initialize component and component count buffers for processed past
        // component types.
        foreach(index, Component; ProcessedComponents)
        {
            enum id  = Component.ComponentTypeID;
            // Untyped component buffer to cast to a typed slice.
            auto raw = (*pastComponents_)[id].buffer.committedComponentSpace;

            mixin(q{
            %s = cast(immutable(ProcessedComponents[%s][]))raw;
            %s = &(*pastComponents_)[id].counts;
            }.format(bufferName!Component, index, countsName!id));
        }

        static if(!noFuture)
        {
            enum futureID = FutureComponent.ComponentTypeID;
            futureComponents_ = &entityManager.future_.components[futureID];
        }

        // Skip dead past entities at the beginning, if any, so front() points
        // to an alive entity (unless we're empty)
        skipDeadEntities();
    }

    /// Get the current past entity.
    Entity front() @safe pure nothrow const
    {
        return pastEntities_[pastEntityIndex_];
    }

    /// True if we've processed all alive past entities.
    bool empty() @safe pure nothrow
    {
        // Only live entities are in futureEntities; if we're at the end, the
        // rest of past entities are dead and we don't need to process them.
        return futureEntityIndex_ >= futureEntities_.length;
    }

    /// Move to the next alive past entity (end the range if no alive entities
    /// left).
    ///
    /// Also moves to the next future entity (which is the same as the next
    /// alive past entity) and moves to the components of the next entity.
    void popFront() @trusted
    {
        assert(!empty, "Trying to advance an empty entity range");
        const past   = pastEntities_[pastEntityIndex_].id;
        const future = futureEntities_[futureEntityIndex_].id;
        assert(past == future,
               "The past (%s) and future (%s) entity is not the same. Maybe we "
               "forgot to skip a dead past entity, or we copied a dead entity "
               "into future entities, or we inserted a new entity elsewhere "
               "than the end of future entities.".format(past, future));
        assert(pastComponent!LifeComponent().alive,
               "Current entity is dead. Likely a bug in how skipDeadEntities "
               "is called.");

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
        mixin(q{return %s[componentOffsets_[id]];}
              .format(bufferName!Component));
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
        const length = (*%s)[pastEntityIndex_];
        return %s[offset .. offset + length]; 
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
        ubyte[] unused = futureComponents_.buffer
                         .forceUncommittedComponentSpace(neededSpace);
        return *cast(FutureComponent*)(unused.ptr);
    }

    }
    // Multi future component.
    else
    {

    /// Get a slice to write future multicomponents for the current entity to.
    /// The slice is at least FutureComponent.maxComponentsPerEntity long.
    FutureComponent[] futureComponent() @trusted nothrow
    {
        enum maxComponents = maxComponentsPerEntity!(FutureComponent);
        // Ensures the needed space is allocated.
        ubyte[] unused = futureComponents_.buffer
                         .forceUncommittedComponentSpace(maxComponents);
        return (cast(FutureComponent*)(unused.ptr))[0 .. maxComponents];
    }

    }

    /// Specify the number of future components written for the current entity.
    ///
    /// May be called more than once while processing an entity; the last call
    /// must pass the number of components actually written.
    ///
    /// Params: count = The number of components written. Must be 0 or 1 for
    ///                 non-multi components.
    void setFutureComponentCount(const ComponentCount count)
        @safe pure nothrow
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
        // Type IDs of component types we're matching (must be a subset of
        // processedIDs)
        enum sortedIDs    = std.algorithm.sort([ComponentTypeIDs]);
        static assert(sortedIDs.setDifference(processedIDs).empty,
                      "One or more matched component types are not processed "
                      "by this EntityAccess.");

        static string matchCode()
        {
            // If the component count for any required component type is 0, the
            // product of multiplying them all is 0. If all are at least 1, the
            // result is true.
            string[] parts;
            foreach(id; ComponentTypeIDs)
            {
                parts ~= q{(*%s)[pastEntityIndex_]}.format(countsName!id);
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
        // Generate code for every processed component type to move past the
        // components in this entity.
        foreach(C; ProcessedComponents)
        {
            enum id = C.ComponentTypeID;
            mixin(q{
            componentOffsets_[id] += (*%s)[pastEntityIndex_];
            }.format(countsName!id));
        }
        ++pastEntityIndex_;
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

    /// A debug method to print the component counts of processed component
    /// types in the current entity.
    void printComponentCounts()
    {
        string[] parts;
        foreach(C; ProcessedComponents)
        {
            enum id = C.ComponentTypeID;
            mixin(q{
            const count = (*%s)[pastEntityIndex_];
            }.format(countsName!id));
            parts ~= "%s: %s".format(id, count);
        }
        return writefln("Component counts (typeid: count):\n%s",
                        parts.join(","));
    }
}
