//          Copyright Ferdinand Majerech 2013-2014.
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
import tharsis.entity.entityrange;
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
///
/// TODO usage example once stable.
class EntityManager(Policy)
{
    mixin validateEntityPolicy!Policy;

    /// Allows EntityRange to access the policy.
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
        const pastEntityCount   = newPast.entities.length;
        newPast.entities.length = pastEntityCount + addedEntityCount;
        auto addedPastEntities  = newPast.entities[pastEntityCount .. $];

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

    /// When used as an argument for a process() method of a Process, provides
    /// access to the current entity handle and components of all past entities.
    ///
    /// See_Also: tharsis.entity.entityrange.EntityAccess
    alias Context = EntityAccess!(typeof(this));

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

        /// Component counts for every entity (counts[i] is the number of
        /// components for entity at entities[i] in entity storage).
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
        /*
         * TODO: An alternative implementation of GameState storage to try:
         *
         * For every component type, there is a buffer of
         * entityID-componentIdx pairs.
         *
         * Each pair says 'this entity has this component'. If the entity has
         * more than 1 component, simply have multiple pairs. (Or, for
         * MultiComponents, use triplets instead of pairs, with the last member
         * of the triplet being component count)
         *
         * When running a process, we run only through buffers of the relevant
         * component types. Meaning we don't run over _all_ entities.
         * Especially relevant for systems processing unusual components.
         *
         *
         * We could implement this and compare speed.
         * Perhaps even have 2 switchable implementations
         * (within the entity manager) - depending on performance either
         * a class member with derived implementations or a struct template
         * parameter.
         */
        /// Stores components of all entities.
        ComponentState components;

        /// All existing entities (either past or future).
        ///
        /// Ordered by entity ID. This is necessary to enable direct component
        /// access through EntityAccess.
        ///
        /// The entire length of this array is used; it doesn't have a unused
        /// part at the end.
        Entity[] entities;

        /*
         * TODO:
         *
         * We may add a structure to access entities by entity IDs. That would
         * speed up direct component access through EntityAccess (which
         * currently uses binary search). We could use a hash map of some kind,
         * or a multi-level bucket-sorted structure (?)
         * (E.g. with 65536 buckets for the first 16 bytes of the entity ID,
         * and arrays/slices within those buckets)
         *
         * Would have to be updated with the entity array between frames.
         * frames that would store the
         */
    }


    /// Register a Process.
    ///
    /// Params: process = Process to register. For every component type there
    ///                   may be at most 1 process writing it (specifying it as
    ///                   it's OutComponentType). The OutComponentType of the
    ///                   process must be registered with the
    ///                   ComponentTypeManager passed to the EntityManager's
    ///                   constructor.
    /// concept, process() signature and overloads, etc.
    void registerProcess(P)(P process) @trusted
    {
        mixin validateProcess!P;
        // True if the Process does not write to any future component.
        // Usually processes that only read past components and produce
        // some kind of output.
        enum noFuture = !hasFutureComponent!P;

        // All overloads of the process() method in the process.
        alias overloads     = processOverloads!P;

        writef("Registering process %s: %s overloads reading past components "
               "%s ", P.stringof,
               overloads.length, componentIDs!(AllPastComponentTypes!P));
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
            //XXX DOC in some description of the Process concept
            // If the process has a 'preProcess' method, call it before
            // processing any entities.
            static if(hasMember!(P, "preProcess")) { process.preProcess(); }

            // Iterate over all alive entities, executing the process on those
            // that match the process() methods of the Process.

            // Using a for instead of foreach because DMD insists on copying the
            // range in foreach for some reason, breaking the code.
            for(auto entityRange = EntityRange!(typeof(this), P)(self);
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

        /// Generate a string with arguments to pass to a process() method.
        ///
        /// Mixed into the process() call at compile time. Should correctly
        /// handle past component, future component and EntityAccess arguments
        /// regardless of their order.
        ///
        /// Params: futureString = String to mix in to pass the future
        ///                        component/s (should be the name of a variable
        ///                        defined where the result is mixed in).
        ///                        Should be null if process() writes no future
        ///                        component/s.
        string processArgs(string futureString = null)()
        {
            string[] parts;
            size_t pastIndex = 0;

            foreach(Param; processMethodParamInfo!F)
            {
                static if(Param.isEntityAccess)
                {
                    parts ~= "entityRange.entityAccess";
                }
                else static if(Param.isComponent)
                {
                    static if(isMutable!(Param.Component))
                    {
                        assert(futureString !is null,
                               "future component not specified");
                        parts ~= futureString;
                    }
                    else
                    {
                        parts ~= q{entityRange.pastComponent!(PastTypes[%s])}
                                 .format(pastIndex);
                        ++pastIndex;
                    }
                }
                else static assert(false, "Unsupported process() parameter: " ~
                                          Param.stringof);
            }
            return parts.join(", ");
        }

        // Call a process() method that does not write a future component.
        static if(noFuture)
        {
            mixin(q{process.process(%s);}.format(processArgs()));
        }
        // The process() method writes a slice of multicomponents of some type.
        else static if(isMultiComponent!(P.FutureComponent))
        {
            // Pass a slice by ref (checked by process validation). The process
            // will downsize the slice to the size it uses.
            P.FutureComponent[] future = entityRange.futureComponent();
            // For the assert below to check that process() doesn't do anything
            // funky like change the slice to point elsewhere.
            debug { auto old = future; }

            // Call the process() method.
            mixin(q{ process.process(%s); }.format(processArgs!"future"()));

            // For some reason, this is compiled in release mode; we use 'debug'
            // to explicitly make it debug-only.
            debug assert(old.ptr == future.ptr && old.length >= future.length,
                         "Process writing a future MultiComponent either "
                         "changed the passed future MultiComponent slice to "
                         "point to another location, or enlarged it");

            // The number of components written.
            const componentCount = cast(ComponentCount)future.length;
            entityRange.setFutureComponentCount(componentCount);
        }
        // If the future component is passed by pointer, process() may refuse to
        // write a future component.
        else static if(futureComponentByPointer!F)
        {
            // Pass pointer by reference; allows process() to set this to null.
            P.FutureComponent* future = &entityRange.futureComponent();
            mixin(q{ process.process(%s); }.format(processArgs!"future"()));
            // If set to null, the future component was not written.
            if(future !is null) { entityRange.setFutureComponentCount(1); }
        }
        // Call a process() method that takes the future component by reference.
        else
        {
            mixin(q{process.process(%s);}
                  .format(processArgs!"entityRange.futureComponent"()));
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
    ///                            entities to. Must have enough space to add
    ///                            all new entities from entitiesToAdd_.
    ///          targetFuture    = Future entities to add the newly created
    ///                            entities to. (They need to be added for
    ///                            processes to run - processes running during
    ///                            the next frame will then decide whether or
    ///                            not they will continue to live). Must have
    ///                            enough space to add all new entities from
    ///                            entitiesToAdd_.
    void addNewEntities(ref ComponentState target,
                        const size_t baseEntityCount,
                        Entity[] targetPast,
                        Entity[] targetFuture) @trusted nothrow
    {
        auto entitiesToAdd = cast(EntitiesToAdd)&entitiesToAdd_;
        const(ComponentTypeInfo)[] compTypeInfo =
            componentTypeManager_.componentTypeInfo;
        foreach(index, pair; entitiesToAdd.prototypes)
        {
            immutable(EntityPrototype)* prototype = pair[0];

            // Component counts of each component type for this entity.
            ComponentCount[maxComponentTypes!Policy] componentCounts;

            // Copy components from the prototype to component buffers.
            foreach(const rawComponent;
                    prototype.constComponentRange(compTypeInfo))
            {
                // Copies and commits the component.
                target[rawComponent.typeID].buffer.addComponent(rawComponent);
                ++componentCounts[rawComponent.typeID];
            }

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
                const globalIndex = baseEntityCount + index;
                const offset = globalIndex == 0
                             ? 0
                             : target[typeID].offsets[globalIndex - 1] + count;
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
            TestSource loadSource(string name, bool logErrors = false) @safe nothrow
            {
                assert(false);
            }
        }

        bool isNull() @safe nothrow const
        {
            assert(false);
        }

        string errorLog() @safe pure nothrow const 
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
    auto compTypeMgr = new ComponentTypeManager!TestSource(TestSource.Loader());
    compTypeMgr.registerComponentTypes!TimeoutComponent();
    compTypeMgr.registerComponentTypes!PhysicsComponent();
    compTypeMgr.lock();
    auto entityManager = new EntityManager!DefaultEntityPolicy(compTypeMgr);
    auto process = new CopyProcess!TimeoutComponent();
    entityManager.registerProcess(process);
}
