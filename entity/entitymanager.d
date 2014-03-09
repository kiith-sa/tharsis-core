//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.entity.entitymanager;


import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import std.string;
import std.traits;
import std.typetuple;
import std.typecons;
import core.sync.mutex;

import tharsis.entity.componentbuffer;
import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitypolicy;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.entityprototype;
import tharsis.entity.lifecomponent;
import tharsis.entity.processtypeinfo;
import tharsis.entity.processwrapper;
import tharsis.entity.resourcemanager;
import tharsis.util.bitmanip;
import tharsis.util.mallocarray;



/// The central, "World" object of Tharsis.
///
/// EntityManager fullfills multiple roles:
/// 
/// * Registers processes and resource managers.
/// * Creates entities from entity prototypes.
/// * Executes processes.
/// * Manages past and future entities and components.
///
/// Params: Policy = A struct with enum members specifying various compile-time 
///                  parameters and hints. See entitypolicy.d for an example.
class EntityManager(Policy)
{
    mixin validateEntityPolicy!Policy;

    /// Allows EntityAccess to access the policy.
    alias EntityPolicy = Policy;

    alias Policy.ComponentCount ComponentCount;

package:
    /// Game state from the previous frame. Stores entities and their 
    /// components, including dead entities and entities that were added during 
    /// the last frame.
    immutable(GameState)* past_;

    /// Game state in the current frame. Stores entities and their components,
    /// including entities hat were added during the last frame.
    GameState* future_;

private:
    /// If writtenComponentTypes_[i] is true, there is a process that writes 
    /// components of type with ComponentTypeID equal to i.
    bool[maxComponentTypes!Policy] writtenComponentTypes_;

    /// Multiplier to apply when preallocating buffers.
    double allocMult_ = 1.0;

    /// Stores both past and future game states.
    ///
    /// The past_ and future_ pointers are exchanged every frame, replacing past 
    /// with future and vice versa to reuse memory,
    GameState[2] stateStorage_;

    /// Wrappers that execute registered processes.
    AbstractProcessWrapper!Policy[] processes_;

    /// Registered resource managers.
    AbstractResourceManager[] resourceManagers_;

    /// Component type manager, including type info about registered component 
    /// types.
    AbstractComponentTypeManager!Policy componentTypeManager_;


    /// A simple class wrapper over entities to add when the next frame starts.
    ///
    /// A class is used to allow convenient use of synchronized and shared.
    /// A struct + mutex could be used if needed, but the GC overhead of this
    /// single instance is very low.
    class EntitiesToAdd
    {
        /// The ID of the next entity that will be created.
        ///
        /// 1 is used to ease detection of bugs with uninitialized data.
        uint nextEntityID = 1;
        /// Stores pointers to prototypes and IDs of the entities to add when
        /// the next frame starts.
        MallocArray!(Tuple!(immutable(EntityPrototype)*, EntityID)) prototypes;
    }

    /// Entities to add when the next frame starts.
    shared(EntitiesToAdd) entitiesToAdd_;

public:
    /// Construct an EntityManager using component types registered with passed
    /// ComponentTypeManager.
    ///
    /// Params: componentTypeManager = Component type manager storing component 
    ///                                type information. Must be locked.
    this(AbstractComponentTypeManager!Policy componentTypeManager)
    {
        componentTypeManager_ = componentTypeManager;
        foreach(ref info; componentTypeInfo)
        {
            if(info.isNull) { continue; }
            foreach(ref state; stateStorage_)
            {
                state.components[info.id].enable(info);
            }
        }

        entitiesToAdd_ = cast(shared(EntitiesToAdd))new EntitiesToAdd();
        auto entitiesToAdd = cast(EntitiesToAdd)&entitiesToAdd_;
        entitiesToAdd.prototypes.reserve(Policy.maxNewEntitiesPerFrame);

        past_   = cast(immutable(GameState*))&(stateStorage_[0]);
        future_ = &(stateStorage_[1]);
    }

    /// Destroy the EntityManager.
    ///
    /// Must be called after using the entity manager.
    ///
    /// Params: clearResources = Destroy all resources in the registered
    ///                          resource managers? If this is false, the user
    ///                          must manually call the clear() method of every
    ///                          resource manager to free the resources.
    void destroy(Flag!"ClearResources" clearResources = Yes.ClearResources)
        @trusted
    {
        .destroy(cast(EntitiesToAdd)entitiesToAdd_);
        if(clearResources) foreach(manager; resourceManagers_)
        {
            manager.clear();
        }
    }

    /// Add a new entity, using components from specified prototype.
    ///
    /// The new entity will be added at the beginning of the next frame.
    ///
    /// Params:  prototype = Prototype of the entity to add.
    ///                      Usually, the prototype will have to be casted to
    ///                      immutable when passed here.
    ///                      Must exist and must not be changed until the
    ///                      beginning of the next frame. It can be safely
    ///                      deleted during the next frame.
    ///
    /// Returns: ID of the new entity on success.
    ///          A null ID if we've added more than 
    ///          Policy.maxNewEntitiesPerFrame new entities during one frame.
    EntityID addEntity(ref immutable(EntityPrototype) prototype) @trusted
    {
        // This should be cheap, assuming most of the time only 1 thread
        // adds entities (SpawnerSystem). If slow, allow bulk adding
        // through a struct that locks at ctor/unlocks at dtor.
        auto entitiesToAdd = cast(EntitiesToAdd)&entitiesToAdd_;
        synchronized(entitiesToAdd)
        {
            if(entitiesToAdd.prototypes.length ==
               entitiesToAdd.prototypes.capacity)
            {
                return EntityID.init;
            }

            auto id = EntityID(entitiesToAdd.nextEntityID++);
            entitiesToAdd.prototypes ~= tuple(&prototype, id);
            return id;
        }
    }

    /// Can be set to force more or less preallocation.
    /// 
    /// Useful e.g. before loading a big map.
    ///
    /// Params:  mult = Multiplier for size of preallocations.
    ///                 Must be greater than 0.
    @property void allocMult(const double mult) @safe pure nothrow 
    {
        assert(mult > 0.0, "allocMult parameter set to 0 or less");
        allocMult_ = mult;
    }

    /// Execute a single frame/tick/time step of the game/simulation.
    ///
    /// Does all management needed between frames, and runs all registered 
    /// processes on matching entities once.
    ///
    /// This includes updating the resource managers, swapping past and future 
    /// state, forgetting dead entities, creating entities added by addEntity,
    /// preallocation, etc.
    void executeFrame()
    {
        frameDebug();
        updateResourceManagers();

        // Past entities from the previous frame may be longer or equal, but 
        // never shorter than the future entities from the previous frame.
        // The reason is that any dead entities from past were not copied to 
        // future (any new entities were copied to both).
        assert(past_.entities.length >= future_.entities.length, 
               "Past entities from the previous frame shorter than future "
               "entities from the previous frame. Past entities may be longer "
               "or equal, never shorter than the future entities. The reason "
               "is that any dead entities from past are not copied to future "
               "(newly added entities are copied to both, so they don't affect "
               "relative lengths");

        // Get the past & future component/entity buffers for the new frame.
        GameState* newFuture = cast(GameState*)past_;
        GameState* newPast   = future_;

        newFuture.entities = 
            cast(Entity[])newFuture.entities[0 .. newPast.entities.length];
        // Clear the future (former past) entities to help detect bugs.
        newFuture.entities[] = Entity.init;

        // Get the number of entities added this frame.
        auto entitiesToAdd     = cast(const(EntitiesToAdd))&entitiesToAdd_;
        const addedEntityCount = entitiesToAdd.prototypes.length;

        // Copy alive past entities to future and create space for the newly 
        // added entities in future.
        const futureEntityCount = copyLiveEntitiesToFuture(newPast, newFuture);
        newFuture.entities.length = futureEntityCount + addedEntityCount;
        newFuture.components.resetBuffers();
        auto addedFutureEntities = newFuture.entities[futureEntityCount .. $];

        // Create space for the newly added entities in past.
        const pastEntityCount  = newPast.entities.length;
        newPast.entities.length = pastEntityCount + addedEntityCount;
        auto addedPastEntities = 
            cast(Entity[])newPast.entities[pastEntityCount .. $];

        // Preallocate future component buffer if needed.
        preallocateComponents(newFuture);

        // Inform the entity count buffers about a changed number of entities.
        newPast.components.growEntityCount(newPast.entities.length);
        newFuture.components.growEntityCount(newFuture.entities.length);

        // Add the new entities into the reserved entity/component space.
        addNewEntities(newPast.components, pastEntityCount,
                       addedPastEntities, addedFutureEntities);

        // Assign back to data members.
        future_ = newFuture;
        past_   = cast(immutable(GameState*))(newPast);


        // Run the processes (sequentially so far).
        foreach(process; processes_) { process.run(this); }
    }


    /// All state belonging to one component type.
    ///
    /// Stores the components and component counts for each entity.
    ///
    /// Future versions of both the components and component counts are cleared 
    /// when the frame begins, then added over the course of a frame.
    struct ComponentTypeState
    {
    private:
        /// True if this ComponentTypeState is used by an existing component 
        /// type.
        bool enabled_;

    public:
        /// Stores components as raw bytes.
        ComponentBuffer!Policy buffer;

        /// Stores component counts for every entity (at indices matching 
        /// indices of entities in entity storage).
        MallocArray!ComponentCount counts;

        /// Offsets of the first component for every entity (offsets[i] is the
        /// index of the first component for entity at entities[i] in entity
        /// storage).
        ///
        /// For entities that have zero components of this type, the offset is
        /// uint.max (absurd value to detect bugs).
        ///
        /// Allows fast access to components of any past entity (if we know its
        /// index) - this enables direct component access through EntityAccess.
        MallocArray!uint offsets;

        /// Destroy the ComponentTypeState.
        ~this()
        {
            // Not necessary, but useful to catch bugs.
            if(enabled_) { reset(); }
        }

        /// Enable the ComponentTypeState.
        ///
        /// Called when an existing component type will use this 
        /// ComponentTypeState.
        ///
        /// Params: typeInfo = Type information about the type of components 
        ///                    stored in this ComponentTypeState.
        void enable(ref const(ComponentTypeInfo) typeInfo) @safe pure nothrow
        {
            assert(!enabled_, "Trying to enable ComponentTypeState that's " 
                              "already enabled. Maybe two component types have "
                              "the same ComponentTypeID?");

            buffer.enable(typeInfo.id, typeInfo.size);
            enabled_ = true;
        }

        /// Is there a component type using this ComponentTypeState?
        bool enabled() @safe pure nothrow const { return enabled_; }

        /// Grow the number of entities to store component counts for.
        ///
        /// Can only be used to _increase_ the number of entities. Component
        /// counts for the new entities are set to zero. Used by EntityManager
        /// e.g. after determining the number of future entities and before 
        /// adding newly created entities.
        ///
        /// Params: count = The new entity count. Must be greater than the 
        ///                 current entity count (set by a previous call to 
        ///                 reset or growEntityCount).
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

        /// Reset the buffers, clearing them.
        /// 
        /// Sets the entity count to 0.
        void reset() @safe pure nothrow
        {
            assert(enabled_, "This ComponentTypeState is not enabled");
            buffer.reset();
            counts.clear();
            offsets.clear();
        }
    }

    /// Stores components of all entities (either past or future).
    /// 
    /// Also stores component counts of every component type for every entity.
    struct ComponentState
    {
        /// Stores component/component count buffers for all component types at 
        /// indices set by the ComponentTypeID members of the component types.
        ComponentTypeState[maxComponentTypes!Policy] self_;

        /// Access the component type state array directly.
        alias self_ this;

        /// Clear the buffers.
        ///
        /// Used to clear future component buffers when starting a frame.
        void resetBuffers()
        {
            foreach(ref data; this) if(data.enabled) { data.reset(); }
        }

        /// Inform the component counts buffers about increased (or equal) 
        /// entity count.
        /// 
        /// Called between frames when entities are added.
        void growEntityCount(const size_t count)
        {
            foreach(ref data; this) if(data.enabled) 
            {
                data.growEntityCount(count);
            }
        }
    }

    /// Stores all game state (entities and components).
    ///
    /// EntityManager has two instances of GameState; past and future.
    struct GameState 
    {
        /// Stores components of all entities.
        ComponentState components;

        /// All existing entities (either past or future).
        /// 
        /// The entire length of this array is used; it doesn't have a unused 
        /// part at the end.
        Entity[] entities;
    }
     
    /// A range used to iterate over entities in an EntityManager and their 
    /// components. 
    /// 
    /// Used when executing process P to read past entities and their components 
    /// of types specified by InComponents, and writing future components for 
    /// the future versions of these entities.
    struct EntityRange(P, InComponents...)
    {
    private:
        // True if the Process does not write to any future component.
        // Usually processes that only read past components and produce
        // some kind of output.
        enum noFuture = !hasFutureComponent!P;

        // Indices of the components of the current entity in past component 
        // buffers. Only the indices of iterated component types are used.
        size_t[maxComponentTypes!Policy] componentOffsets_;

        // Index of the past entity we're currently reading.
        size_t pastEntityIndex_ = 0;

        // Index of the future entity we're currently writing to.
        size_t futureEntityIndex_ = 0;

        static if(!noFuture)
        {

        // Future component written by the process (if any).
        alias FutureComponent = P.FutureComponent;

        // Number of future components (of type P.FutureComponent) written 
        // to the current future entity.
        //
        // Ease bug detection with a ridiculous value
        ComponentCount futureComponentCount_ = ComponentCount.max;

        /// Component buffer and counts for the future components written 
        /// by process P.
        ///
        /// We can't keep a typed slice as the internal buffer may get 
        /// reallocated; so we cast on every future component access.
        ComponentTypeState* futureComponents_;

        }

        // Past entities in the entity manager.
        //
        // Past entities that are not alive are ignored.
        immutable(Entity[]) pastEntities_;

        // Future entities in the entity manager.
        //
        // Used to check if the current past entiity matches the current future 
        // entity.
        const(Entity[]) futureEntities_;

        /// All processed component types.
        ///
        /// NoDuplicates! is used to avoid having two elements for the same type 
        /// if the process reads a builtin component type.
        alias NoDuplicates!(TypeTuple!(InComponents, BuiltinComponents))
            ProcessedComponents;

        /// (CTFE) Get the name of the component buffer data member for 
        /// specified component type.
        static string bufferName(C)() @trusted
        {
            return "buffer%s_".format(C.ComponentTypeID);
        }

        /// (CTFE) Get the name of the component count buffer data member for 
        /// specified component type.
        static string countsName(ushort ID)() @trusted
        {
            return "counts%s_".format(ID);
        }

        /// (CTFE) For each processed (past) component type, generate data 
        /// 2 data members: component buffer and  component count buffer.
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

        /// Mixin typed slices to access all processed past components, and
        /// pointers to component count buffers to access the number of 
        /// components of every processed type per entity.
        ///
        /// These are casted from the untyped buffers in the ComponentBuffer
        /// struct of each type.
        mixin(pastComponentBuffers());

        /// No default construction or copying.
        @disable this();
        @disable this(this);

    public:
        /// Construct an EntityRange to iterate over past entities of specified 
        /// entity manager.
        this(EntityManager entityManager)
        {
            pastEntities_   = entityManager.past_.entities;
            futureEntities_ = entityManager.future_.entities;
            auto past       = &entityManager.past_.components;
            // Initialize component and component count buffers for every 
            // processed past component type.
            foreach(index, Component; ProcessedComponents)
            {
                enum id  = Component.ComponentTypeID;
                // Untyped component buffer to cast to a typed slice.
                auto raw = (*past)[id].buffer.committedComponentSpace;

                mixin(q{
                %s = cast(immutable(ProcessedComponents[%s][]))raw;
                %s = &(*past)[id].counts;
                }.format(bufferName!Component, index, countsName!id));
            }

            static if(!noFuture)
            {
                enum futureID = FutureComponent.ComponentTypeID;
                futureComponents_ = &entityManager.future_.components[futureID];
            }

            // Skip dead past entities at the beginning, if any, so front() 
            // points to an alive entity (unless we're empty)
            skipDeadEntities();
        }

        /// Get the current past entity.
        Entity front() @safe pure nothrow 
        {
            return pastEntities_[pastEntityIndex_];
        }

        /// True if we've processed all alive past entities.
        bool empty() @safe pure nothrow
        {
            // Only the surviving entities are in futureEntities;
            // if we're at the last, we don't need to process the rest of the 
            // past entities; they're all dead.
            return futureEntityIndex_ >= futureEntities_.length;
        }

        /// Move to the next alive past entity (or to the end of the range if 
        /// no more alive entities left).
        /// 
        /// Also moves to the next future entity (which is the same as the next 
        /// alive past entity) and moves to the components of the next entity.
        void popFront() @trusted
        {
            assert(!empty,
                   "Trying to get the next element of an empty entity range");
            const past   = pastEntities_[pastEntityIndex_].id;
            const future = futureEntities_[futureEntityIndex_].id;
            assert(past == future,
                   "The current past entity (%s) is different from the current "
                   "future entity (%s). Maybe we didn't skip a dead past "
                   "entity, or we copied a dead entity into future entities, "
                   "or we inserted a new entity elsewhere than at the end of "
                   "future entities".format(past, future));
            assert(pastComponent!LifeComponent().alive,
                   "Current entity in EntityRange.popFront() is not alive. "
                   "Likely a bug in how skipDeadEntities is called.");

            nextFutureEntity();
            nextPastEntity();

            skipDeadEntities();
        }

        /// Access a past (non-multi) component in the current entity.
        ///
        /// Params: Component = Type of component to access.
        ///
        /// Returns: An immutable reference to the past component.
        ref immutable(Component) pastComponent(Component)() 
            @safe nothrow const
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

        /// Get a reference to where the future component for the current entity
        /// should be written (the process() method may still decide not to 
        /// write it).
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

        /// Get a slice to where to write future (multi) components for the 
        /// current entity. The slice is at least
        /// FutureComponent.maxComponentsPerEntity long (the process() method 
        /// may shorten it after passed).
        FutureComponent[] futureComponent() @trusted nothrow
        {
            enum maxComponents = maxComponentsPerEntity!(FutureComponent);
            // Ensures the needed space is allocated.
            ubyte[] unused = futureComponents_.buffer
                             .forceUncommittedComponentSpace(maxComponents);
            return (cast(FutureComponent*)(unused.ptr))[0 .. maxComponents];
        }

        }

        /// Specify the number of future components written for the current 
        /// entity.
        ///
        /// May be called more than once while processing an entity, but the 
        /// final number must match the number of components actually written.
        ///
        /// Params: count = The number of components writte. Must be 0 or 1 for
        ///                 non-multi components.
        void setFutureComponentCount(const ComponentCount count)
            @safe pure nothrow
        {
            assert(isMultiComponent!FutureComponent || count <= 1,
                   "Trying to set future component count for a non-multi "
                   "component to more than 1");
            futureComponentCount_ = count;
        }

        }

        /// Determine if the current entity contains components of all specified 
        /// types.
        bool matchComponents(ComponentTypeIDs...)() @trusted
        {
            // Type IDs all component types this range iterates over.
            enum processedIDs = componentIDs!ProcessedComponents;
            // Type IDs of component types we're matching.
            enum sortedIDs    = std.algorithm.sort([ComponentTypeIDs]);
            static assert(sortedIDs.setDifference(processedIDs).empty, 
                          "One or more matched component types are not "
                          "processed by this ComponentIterator.");

            static string matchCode()
            {
                // If the component count for any required component type is 0,
                // the result of multiplying them all is 0.
                // Af all are at least 1, the result is true.
                string[] parts;
                foreach(id; ComponentTypeIDs)
                {
                    parts ~= q{ 
                    (*%s)[pastEntityIndex_]
                    }.format(countsName!id);
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
            // Generate code for every iterated component type to move past
            // the components in this entity.
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
        /// Also definitively commits the future components for the current 
        /// entity.
        void nextFutureEntity()
            @safe pure nothrow 
        {
            static if(!noFuture)
            {
                enum id = FutureComponent.ComponentTypeID;
                futureComponents_.buffer.commitComponents
                    (futureComponentCount_);
                futureComponents_.counts[futureEntityIndex_] 
                    = futureComponentCount_;
                // Ease bug detection
                futureComponentCount_ = ComponentCount.max;
            }
            ++futureEntityIndex_; 
        }

        /// A debug method to print the component counts for every processed 
        /// component type in the current entity.
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


    /// Register a Process.
    ///
    /// Params: process = Process to register. For every component type there 
    ///                   may be at most 1 process writing it (specifying it as
    ///                   it's OutComponentType). The OutComponentType of the 
    ///                   process must be registered with the 
    ///                   ComponentTypeManager passed to the EntityManager's 
    ///                   constructor.
    void registerProcess(P)(P process) @trusted
    {
        mixin validateProcess!P;
        // True if the Process does not write to any future component.
        // Usually processes that only read past components and produce
        // some kind of output.
        enum noFuture = !hasFutureComponent!P;

        // All overloads of the process() method in the process.
        alias overloads           = processOverloads!P;
        // Component types passed as past components in process() methods of the
        // process.
        alias AllInComponentTypes = AllPastComponentTypes!P;

        writef("Registering process %s: %s overloads reading past components "
               "%s ", P.stringof, 
               overloads.length, componentIDs!AllInComponentTypes);
        static if(!noFuture)
        {
            assert(!writtenComponentTypes_[P.FutureComponent.ComponentTypeID], 
                   "Can't register 2 processes with one future component type");
            assert(componentTypeManager_.areTypesRegistered!(P.FutureComponent),
                   "Registering a process with unregistered future component "
                   "type " ~ P.FutureComponent.stringof);

            // This future component is now taken; no other process can write to it.
            writtenComponentTypes_[P.FutureComponent.ComponentTypeID] = true;
            writefln(" and writing future component %s", 
                     componentIDs!(P.FutureComponent));
        }
        else 
        {
            writefln("");
        }

        // A function executing the process during one frame.
        // 
        // Iterates over past entities. If an entity has all past components in 
        // a signature of one of P.process() overloads, calls that overload,
        // passing refs to those components and a ref/ptr to a future component
        // of type P.FutureComponent.
        //
        // More specific overloads have precedence over more general. For 
        // example, if there are overloads process(A) and process(A, B), and an
        // entity has components A and B, the latter overload is called.
        static void runProcess(EntityManager self, P process)
        {
            // If the process has a 'preProcess' method, call it before 
            // processing any entities.
            static if(hasMember!(P, "preProcess")) { process.preProcess(); }

            // Iterate over all alive entities, executing the process on those
            // that match the process() methods of the Process.

            // Using a for instead of foreach because DMD insists on copying the
            // range in foreach for some reason, breaking the code.
            for(auto entityRange = EntityRange!(P, AllInComponentTypes)(self);
                !entityRange.empty(); entityRange.popFront())
            {
                static if(!noFuture)
                {
                    entityRange.setFutureComponentCount(0); 
                }

                // Generates an if-else chain checking each overload, starting 
                // with the most specific one. 
                mixin(prioritizeProcessOverloads!P.map!(p => q{ 
                    if(entityRange.matchComponents!(%s))
                    {
                        self.callProcessMethod!(overloads[%s])
                                               (process, entityRange);
                    }
                }.format(p[0], p[1])).join("else ").outdent);
            }

            // If the process has a 'postProcess' method, call it after 
            // processing all entities.
            static if(hasMember!(P, "postProcess")) { process.postProcess(); }
        }

        // Add a wrapper for the process,
        processes_ ~= new ProcessWrapper!(P, Policy)(process, &runProcess);
    }

    //XXX need a "locked" state when no new stuff can be registered.
    /// Register specified resource manager.
    ///
    /// Once registered, components may refer to resources managed by this
    /// resource manager, and the EntityManager will update it between frames.
    void registerResourceManager(Manager)(Manager manager) @safe pure nothrow
        if(is(Manager : AbstractResourceManager))
    {
        //XXX assert no other manager manages this type
        resourceManagers_ ~= manager;
    }

package:
    /// Get a resource handle without compile-time type information.
    ///
    /// Params: type       = Type of the resource. There must be a resource 
    ///                      manager managing resources of this type.
    ///         descriptor = A void pointer to the descriptor of the resource.
    ///                      The actual type of the descriptor must be the 
    ///                      Descriptor type of the resource type.
    ///
    /// Returns: A raw handle to the resource.
    RawResourceHandle rawResourceHandle(TypeInfo type, void* descriptor)
        nothrow
    {
        foreach(manager; resourceManagers_)
        {
            if(manager.managedResourceType is type)
            {
                return manager.rawHandle(descriptor);
            }
        }
        assert(false, "No resource manager for type " ~ to!string(type));
    }

private:
    /// Calls specified process() method of a Process.
    ///
    /// Params: F           = The process() method to call.
    ///         process     = Process with the process() method.
    ///         entityRange = Entity range to get the components to pass from.
    static void callProcessMethod 
        (alias F, P, ERange)(P process, ref ERange entityRange)
    {
        // True if the Process does not write to any future component.
        // Usually these processes read past components and produce
        // some kind of output.
        enum noFuture   = !hasFutureComponent!P;
        alias PastTypes = PastComponentTypes!F;

        /// (CTFE) Get components to pass to a process() method, comma separated
        /// in a string. Every item accesses a past component/multicomponents
        /// from the component buffer.
        string pastComponents()
        {
            string[] parts;
            foreach(i, T; PastTypes)
            {
                parts ~= q{entityRange.pastComponent!(PastTypes[%s])}.format(i);
            }
            return parts.join(", ");
        }

        // Call a process() method that does not write a future component.
        static if(noFuture)
        {
            mixin(q{process.process(%s);}.format(pastComponents()));
        }
        // The process() method writes a slice of multicomponents of some type.
        else static if(isMultiComponent!(P.FutureComponent))
        {
            // Pass a slice by ref (enforced by process validation). 
            // The process will downsize the slice to only the size it uses.
            P.FutureComponent[] futureComponents =
                entityRange.futureComponent();
            // For the assert below to ensure the process() method doesn't do
            // anything funky like change the slice to point elsewhere.
            debug { auto oldSlice = futureComponents; }

            // Call the process() method.
            mixin(q{
            process.process(%s, futureComponents);
            }.format(pastComponents()));

            // For some reason, this assert is compiled even in release mode,
            // so we use 'debug' to explicitly disable it outside of debug mode.
            debug assert(oldSlice.ptr == futureComponents.ptr && 
                         oldSlice.length >= futureComponents.length,
                         "Process writing a future MultiComponent either "
                         "changed the passed future MultiComponent slice to "
                         "point to another location, or enlarged it");

            // The number of components written.
            const componentCount = cast(ComponentCount)futureComponents.length;
            entityRange.setFutureComponentCount(componentCount);
        }
        // If the future component is specified by pointer, process() may null 
        // it, in which case the component won't exist in future.
        else static if(futureComponentByPointer!F)
        {
            // This is passed to process() by reference, allowing process() to 
            // set this to null.
            P.FutureComponent* futureComponent = &entityRange.futureComponent();
            mixin(q{
            process.process(%s, futureComponent);
            }.format(pastComponents()));
            // If futureComponent was not set to null, the future component was
            // written.
            if(futureComponent !is null)
            {
                entityRange.setFutureComponentCount(1);
            }
        }
        // Call a process() method that takes the future component by reference.
        else
        {
            mixin(q{process.process(%s, entityRange.futureComponent);}
                  .format(pastComponents()));
            entityRange.setFutureComponentCount(1);
        }
    }

    /// A shortcut to access component type information.
    ref const(ComponentTypeInfo[maxComponentTypes!Policy]) componentTypeInfo()
        @safe pure nothrow const
    {
        return componentTypeManager_.componentTypeInfo;
    }

    ////////////////////////////////////////////
    /// BEGIN CODE CALLED BY execute_frame() ///
    ////////////////////////////////////////////

    /// Show any useful debugging information (warnings) before running a frame,
    /// and check frame invariants.
    void frameDebug() @trusted nothrow
    {
        static void implementation(EntityManager self) 
        {with(self){
            foreach(id; 0 .. maxBuiltinComponentTypes)
            {
                const(ComponentTypeInfo)* info = &componentTypeInfo[id];
                // If no such builtin component type exists, ignore.
                if(info.isNull) { continue; }
                assert(writtenComponentTypes_[id], 
                       "No process writing to builtin component type %s: "
                       "please register a process writing this component type "
                       "(see tharsis.defaults.copyprocess for a "
                       "placeholder process).".format(info.name));
            }
            foreach(ref info; componentTypeInfo)
            {
                if(writtenComponentTypes_[info.id] ||
                   info.id == nullComponentTypeID)
                {
                    continue;
                }
                writefln("WARNING: No process writing to component type %s: "
                         "all components of this type will disappear after the "
                         "first frame.", info.name);
            }
        }}
        (cast(void function(EntityManager) nothrow)&implementation)(this);
    }

    /// Update every resource manager, allowing them to load resources.
    ///
    /// Part of the code executed between frames in executeFrame().
    void updateResourceManagers() @safe nothrow
    {
        foreach(resManager; resourceManagers_) { resManager.update(); }
    }

    /// Copy the surviving entities from past to future entity buffer.
    ///
    /// Part of the code executed between frames in executeFrame().
    ///
    /// Params: past   = The new past, former future state.
    ///         future = The new future, former past state. future.entities must 
    ///                  be exactly as long as past.entities. Surviivng entities
    ///                  will be copied here.
    ///
    /// Returns: The number of surviving entities written to futureEntities.
    static size_t copyLiveEntitiesToFuture 
        (const(GameState)* past, GameState* future) @trusted pure nothrow
    {
        assert(past.entities.length == future.entities.length, 
               "Past/future entity counts do not match");

        // Get the past LifeComponents.
        enum lifeID = LifeComponent.ComponentTypeID;
        auto rawLifeComponents = 
            past.components[lifeID].buffer.committedComponentSpace;
        auto lifeComponents = cast(immutable(LifeComponent)[])rawLifeComponents;

        // Copy the alive entities to the future and count them.
        size_t aliveEntities = 0;
        foreach(i, pastEntity; past.entities) if(lifeComponents[i].alive)
        {
            future.entities[aliveEntities++] = pastEntity;
        }
        return aliveEntities;
    }

    /// Preallocate space in component buffers.
    ///
    /// Part of the code executed between frames in executeFrame().
    ///
    /// Used to preallocate space for future components to minimize allocations
    /// during frame.
    ///
    /// Params: state = Game state (past or future) to preallocate space for.
    void preallocateComponents(GameState* state)
        @safe nothrow
    {
        // Preallocate space for components based on hints in the Policy
        // and component type info.

        // Minimums common for all component types.
        const size_t basePreallocPerEntity = cast(size_t)
           (Policy.minComponentPerEntityPrealloc * state.entities.length);
        enum baseMinPrealloc = Policy.minComponentPrealloc;

        foreach(ref info; componentTypeInfo) if(!info.isNull)
        {
            // Component type specific minimums.
            const size_t minPrealloc = max(baseMinPrealloc, info.minPrealloc);
            const size_t specificPreallocPerEntity = 
                cast(size_t)(info.minPreallocPerEntity * state.entities.length);
            const size_t preallocPerEntity =
                max(basePreallocPerEntity, specificPreallocPerEntity);
            const size_t prealloc =
                cast(size_t)(allocMult_ * max(minPrealloc, preallocPerEntity));
            state.components[info.id].buffer.reserveComponentSpace(prealloc);
        }
    }

    /// Add newly created entities (from the entitiesToAdd_ data member).
    ///
    /// Part of the code executed between frames in executeFrame().
    ///
    /// Params:  target          = Past component buffers to add components of
    ///                            the added entities to. We're adding entities
    ///                            created during the previous frame, so the 
    ///                            next frame will see them as past state. 
    ///                            Whether the components will also exist in the 
    ///                            future is up to the processes that will 
    ///                            process them.
    ///          baseEntityCount = The number of past entities (before these 
    ///                            entities are added).
    ///          targetPast      = Past entities to add the newly created 
    ///                            entities to.
    ///          targetFuture    = Future entities to add the newly created 
    ///                            entities to. (They need to be added for 
    ///                            processes to run - only the processes running
    ///                            during the next frame will decide whether or 
    ///                            not they will continue to live).
    void addNewEntities(ref ComponentState target,
                        const size_t baseEntityCount,
                        Entity[] targetPast,
                        Entity[] targetFuture) @trusted nothrow
    {
        auto entitiesToAdd = cast(EntitiesToAdd)&entitiesToAdd_;
        foreach(index, pair; entitiesToAdd.prototypes)
        {
            immutable(EntityPrototype)* prototype = pair[0];
            const(ubyte)[] rawBytes = prototype.rawComponentBytes;

            // Component counts of each component type for this entity.
            ComponentCount[maxComponentTypes!Policy] componentCounts;
            // Copy components from the prototype to component buffers.
            foreach(typeID; prototype.componentTypeIDs)
            {
                // Copies and commits the component.
                rawBytes = target[typeID].buffer.addComponent(rawBytes);
                ++componentCounts[typeID];
            }

            // Add a (mandatory) LifeComponent.
            enum lifeID = LifeComponent.ComponentTypeID;
            const life  = LifeComponent(true);
            auto source = cast(const(ubyte)[])((&life)[0 .. 1]);
            target[lifeID].buffer.addComponent(source);
            ++componentCounts[lifeID];

            // Add the new entity to past/future entities.
            const EntityID entityID = pair[1];
            targetPast[index] = targetFuture[index] = Entity(entityID);

            // Set the component counts/offsets for this entity.
            foreach(typeID, count; componentCounts) 
            {
                if(!target[typeID].enabled) { continue; }
                const globalIndex = baseEntityCount + index;
                const offset = globalIndex == 0 
                             ? 0
                             : target[typeID].counts[globalIndex - 1] + count;
                target[typeID].counts[globalIndex]  = count;
                target[typeID].offsets[globalIndex] = offset;
            }
        }

        // Clear to reuse during the next frame.
        entitiesToAdd.prototypes.clear();
    }

    //////////////////////////////////////////
    /// END CODE CALLED BY execute_frame() ///
    //////////////////////////////////////////
}

unittest 
{
    /// Not a 'real' Source, just for testing.
    struct TestSource 
    {
    public:
        struct Loader
        {
            TestSource loadSource(string name) @safe nothrow 
            {
                assert(false);
            }
        }

        bool isNull() @safe nothrow const
        {
            assert(false);
        }

        bool readTo(T)(out T target) @safe nothrow
        {
            assert(false);
        }

        bool getSequenceValue(size_t index, out TestSource target) @safe nothrow
        {
            assert(false);
        }

        bool getMappingValue(string key, out TestSource target) @safe nothrow 
        {
            assert(false);
        }
    }

    struct TimeoutComponent
    {
        enum ushort ComponentTypeID = userComponentTypeID!1;

        enum minPrealloc = 8192;

        int killEntityIn;
    }

    struct PhysicsComponent
    {
        enum ushort ComponentTypeID = userComponentTypeID!2;

        enum minPrealloc = 16384;

        enum minPreallocPerEntity = 1.0;

        float x;
        float y;
        float z;
    }


    import tharsis.defaults.copyprocess;
    auto compTypeMgr = 
        new ComponentTypeManager!TestSource(TestSource.Loader());
    compTypeMgr.registerComponentTypes!TimeoutComponent();
    compTypeMgr.registerComponentTypes!PhysicsComponent();
    compTypeMgr.lock();
    auto entityManager = new EntityManager!DefaultEntityPolicy(compTypeMgr);
    auto process = new CopyProcess!TimeoutComponent();
    entityManager.registerProcess(process);
}
