//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.entity.entitymanager;


import std.algorithm;
import std.array;
import std.conv;
import std.exception: assumeWontThrow;
import std.stdio;
import std.string;
import std.traits;
import std.typetuple;
import std.typecons;
import core.sync.mutex;

import tharsis.prof;

import tharsis.entity.componentbuffer;
import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitypolicy;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.entityprototype;
import tharsis.entity.entityrange;
import tharsis.entity.gamestate;
import tharsis.entity.lifecomponent;
import tharsis.entity.processtypeinfo;
import tharsis.entity.processwrapper;
import tharsis.entity.resourcemanager;
import tharsis.entity.scheduler;
import tharsis.util.bitmanip;
import tharsis.util.mallocarray;
import tharsis.util.time;


/// A shortcut alias for EntityManager with the default entity policy.
alias DefaultEntityManager = EntityManager!DefaultEntityPolicy;

/** The central, "World" object of Tharsis.
 *
 * EntityManager fullfills multiple roles:
 *
 * * Registers processes and resource managers.
 * * Creates entities from entity prototypes.
 * * Executes processes.
 * * Manages past and future entities and components.
 *
 * Params: Policy = A struct with enum members specifying various compile-time
 *                  parameters and hints. See entitypolicy.d for an example.
 *
 * TODO usage example once stable.
 */
class EntityManager(Policy)
{
    mixin validateEntityPolicy!Policy;

    /// Allows EntityRange to access the policy.
    alias EntityPolicy = Policy;

    /// Shortcut alias.
    alias ComponentCount = Policy.ComponentCount;

    import tharsis.entity.diagnostics;
    /// Struct type to store diagnostics info in.
    alias Diagnostics = EntityManagerDiagnostics!Policy;

package:
    /// Shortcut aliases.
    alias GameStateT          = GameState!Policy;
    alias ComponentStateT     = ComponentState!Policy;
    alias ComponentTypeStateT = ComponentTypeState!Policy;


    import core.thread;
    /** A thread that runs processes each frame.
     *
     * The thread alternates between states:
     *
     * When a game update starts, EntityManager changes the state to Executing (by a
     * startUpdate() call), which is detected by the ProcessThread which then begins
     * executing Processes (as determined by the Scheduler) for the game update. Once
     * the ProcessThread is done running the Processes, it sets its state to Waiting.
     * EntityManager waits until all ProcessThreads are Waiting to end the game update.
     *
     * On the next game update, this sequence repeats.
     *
     * EntityManager stops all ProcessThreads at its deinitialization by calling stop(),
     * changing ProcessThread state to Stopping, which is detected by the ProcessThread
     * which then stops.
     */
    static class ProcessThread : Thread
    {
        /// Possible states of a ProcessThread.
        enum State: ubyte
        {
            // Executing processes in a game update.
            Executing,
            // Waiting for the next game update after done executing the last one.
            Waiting,
            // Stopping the thread.
            //
            // Set by EntityManager to signify that the thread should stop.
            Stopping,
        }

    private:
        // Using atomic *stores* to set state_ but don't use atomic loads to read it:
        // The value won't get 'teared' since it's 1 byte.

        // Current state of the thread. Use atomic stores to write, normal reads to read.
        shared(State) state_ = State.Waiting;

        // The entity manager (called self_ because this is essentially EntityManager code).
        EntityManager self_;

        // Index of this thread (main thread is 0, first external thread 1, next 2, etc.)
        uint threadIdx_;

        // Name of the thread (for profiling/debugging).
        string threadName_;

        // package avoids invariants, which slow down state() to crawl in debug builds.
    package:
        /** Construct a ProcessThread.
         *
         * Params:
         *
         * self      = The entity manager. The ProcessThread is essentially EntityManager
         *             code moved into a separate thread.
         * threadIdx = Index of the thread. 0 is the main thread, 1 the first
         *             ProcessThread, etc.
         */
        this(EntityManager self, uint threadIdx) @system nothrow
        {
            self_      = self;
            threadIdx_ = threadIdx;
            threadName_ = "Tharsis ExecuteThread %s".format(threadIdx_).assumeWontThrow;
            super( &run ).assumeWontThrow;
        }

        /// Get the current state of the thread.
        final State state() @system pure nothrow @nogc { return cast(State)state_; }

        import core.atomic;
        /** Stop the thread. Should be called only by EntityManager.
         * Can only be called once execution of any game update is finished (i.e. when
         *
         * the thread is in Waiting state).
         */
        final void stop() @system nothrow
        {
            assert(isRunning, "Trying to stop() a thread that is not running");
            assert(state == State.Waiting, "Trying to stop a ProcessThread that is "
                                           "either executing or is already stopping");
            atomicStore(state_, State.Stopping);
        }

        /** Start executing processes in a game update. Should be called only by EntityManager.
         *
         * Can only be called when the thread is in Waiting state.
         */
        final void startUpdate() @system nothrow
        {
            assert(isRunning, "Trying to startUpdate() in a thread that is not running");
            assert(state == State.Waiting, "Trying to start an update on an ProcessThread "
                                           "that is either executing or is stopping");
            atomicStore(state_, State.Executing);
        }

        /// Code that runs in the ProcessThread.
        void run() @system nothrow
        {
            bool profilerExists = self_.externalProfilers_.length > threadIdx_;
            auto profiler       = profilerExists ? self_.externalProfilers_[threadIdx_] : null;
            auto threadZone     = Zone(profiler, threadName_);

            for(;;) final switch(state)
            {
                case State.Waiting:
                    // Wait for the next game update (and measure the wait with profiler).
                    auto waitingZone = Zone(profiler, "waiting");
                    while(state == State.Waiting)
                    {
                        // We need to give the OS some time to do other work... otherwise
                        // if we hog all cores the OS will stop our threads in
                        // inconvenient times.
                        import std.datetime;
                        try { sleep(dur!"msecs"(0)); }
                        // TODO: log this, eventually 2014-09-17
                        catch(Exception e)
                        {
                            // ignore, resulting in a hot loop
                        }
                        continue;
                    }
                    break;
                case State.Executing:
                    {
                        // scope(exit) ensures the state is set even if we're crashing
                        // with a Throwable (to avoid EntityManager waiting forever).
                        scope(exit) { atomicStore(state_, State.Waiting); }
                        self_.executeProcessesOneThread(threadIdx_);
                        // Ensure any memory ops finish before finishing a game update.
                        atomicFence();
                    }
                    break;
                case State.Stopping:
                    // return, finishing the thread.
                    return;
            }
        }
    }

    /// Game state from the previous frame. Stores entities and their components,
    /// including dead entities and entities that were added during the last frame.
    immutable(GameStateT)* past_;

    /// Game state in the current frame. Stores entities and their components, including
    /// entities hat were added during the last frame.
    GameStateT* future_;

    /// Component type manager, including type info about registered component types.
    AbstractComponentTypeManager componentTypeMgr_;

private:
    /// If writtenComponentTypes_[i] is true, there is a process that writes components
    /// of type with ComponentTypeID equal to i.
    bool[maxComponentTypes!Policy] writtenComponentTypes_;

    /// Multiplier to apply when preallocating buffers.
    double allocMult_ = 1.0;

    /// Stores both past and future game states.
    ///
    /// The past_ and future_ pointers are exchanged every frame, replacing past with
    /// future and vice versa to reuse memory,
    GameStateT[2] stateStorage_;

    /// Wrappers that execute registered processes.
    AbstractProcessWrapper!Policy[] processes_;

    /// Registered resource managers.
    AbstractResourceManager[] resourceManagers_;

    /** A simple class wrapper over entities to add when the next frame starts.
     *
     * A class is used to allow convenient use of synchronized and shared. A struct +
     * mutex could be used if needed, but GC overhead of a single instance is very low.
     */
    class EntitiesToAdd
    {
        /// The ID of the next entity that will be created.
        ///
        /// 1 is used to ease detection of bugs with uninitialized data.
        uint nextEntityID = 1;
        /// Stores pointers to prototypes and IDs of the entities to add when the next
        /// frame starts.
        MallocArray!(Tuple!(immutable(EntityPrototype)*, EntityID)) prototypes;
    }

    /// Entities to add when the next frame starts.
    shared(EntitiesToAdd) entitiesToAdd_;

    /// Determines which processes run in which threads.
    Scheduler scheduler_;

    /// Process threads (all threads executing processes other than the main thread).
    ProcessThread[] procThreads_;

    /// Diagnostics data (how many components of which type, etc).
    Diagnostics diagnostics_;

    /** Profilers attached by $(D attachPerThreadProfilers())
     *
     * If no profilers are attached, this contains one null reference so we can pass
     * externalProfilers_[0] to zones without complicating code.
     *
     * Used to profile Tharsis itself and Tharsis as a part of a bigger program.
     */
    Profiler[] externalProfilers_;

    /// Frame profilers (per-thread) used to determine overhead of individual Processes.
    Profiler[] processProfilers_;

    /// Process names longer than this are cut for profiling zone names.
    enum profilerNameCutoff = 128;

    /// Storage used by processProfilers_ to record profile data to.
    ubyte[][] processProfilersStorage_;

public:
    /** Construct an EntityManager using component types registered in a ComponentTypeManager.
     *
     * Params:
     *
     * componentTypeManager = Component type manager storing component type information.
     *                        Must be locked.
     * overrideThreadCount  = If nonzero, the EntityManager will always use the specified
     *                        number of threads (even if there are too few processes to
     *                        use them) instead of autodetecting optimal thread count.
     */
    this(AbstractComponentTypeManager componentTypeManager, size_t overrideThreadCount = 0)
        @trusted nothrow
    {
        scheduler_ = new Scheduler(overrideThreadCount);

        // Start the process threads.
        // 0 is the main thread, so we only need to add threads other than 0.
        foreach(threadIdx; 1 .. scheduler_.threadCount)
        {
            procThreads_ ~= new ProcessThread(this, cast(uint)threadIdx);
            procThreads_.back.start().assumeWontThrow;
        }

        import core.stdc.stdlib: malloc;
        // For now, we assume 128kiB is enough for zones for all Processes in a thread. It
        // should be OK as long as the user doesn't have thousands of Processes (note that
        // running out of this space will not *break* Tharsis, but it will lead to
        // inability to effectively schedule processes (but... any user with 1000s of
        // processes is pretty much asking for it))
        foreach(thread; 0 .. scheduler_.threadCount)
        {
            processProfilersStorage_ ~= (cast(ubyte*)malloc(128 * 1024))[0 .. 128 * 1024];
            processProfilers_        ~= new Profiler(processProfilersStorage_.back);
        }

        // 1 null reference so we can easily use Zones in the main thread.
        externalProfilers_ = [null];

        componentTypeMgr_ = componentTypeManager;
        // Explicit initialization is needed as of DMD 2.066, may be redundant later.
        (stateStorage_[] = GameStateT.init).assumeWontThrow;
        foreach(ref info; componentTypeInfo)
        {
            if(info.isNull) { continue; }
            foreach(ref state; stateStorage_)
            {
                state.components[info.id].enable(info);
            }
        }

        entitiesToAdd_ = cast(shared(EntitiesToAdd))new EntitiesToAdd();
        auto entitiesToAdd = cast(EntitiesToAdd)entitiesToAdd_;
        entitiesToAdd.prototypes.reserve(Policy.maxNewEntitiesPerFrame);

        past_   = cast(immutable(GameStateT*))&(stateStorage_[0]);
        future_ = &(stateStorage_[1]);
    }

    /** Destroy the EntityManager.
     *
     * Must be called after using the entity manager.
     *
     * Params: clearResources = Destroy all resources in registered resource managers? If
     *                          false, the user must manually call the clear() method of
     *                          every resource manager to free the resources.
     */
    void destroy(Flag!"ClearResources" clearResources = Yes.ClearResources)
        @trusted
    {
        auto zoneDtor = Zone(externalProfilers_[0], "EntityManager.destroy");
        .destroy(cast(EntitiesToAdd)entitiesToAdd_);
        if(clearResources) foreach(manager; resourceManagers_)
        {
            manager.clear();
        }

        // Tell all process threads to stop and then wait to join them.
        foreach(thread; procThreads_) { thread.stop(); }
        try foreach(thread; procThreads_)
        {
            thread.join();
        }
        catch(Throwable e)
        {
            // TODO: Logging 2014-09-17
            import std.stdio;
            writeln("EntityManager thread terminated with an error:").assumeWontThrow;
            writeln(e).assumeWontThrow;
            assert(false);
        }

        import core.stdc.stdlib: free;
        .destroy(scheduler_);
        foreach(profiler; processProfilers_) { .destroy(profiler); }
        .destroy(processProfilers_);
        foreach(storage; processProfilersStorage_) { free(storage.ptr); }
        .destroy(processProfilersStorage_);
    }

    /** Attach multiple Profilers, each of which will profile a single thread.
     *
     * Can be used for to profile Tharsis execution as a part of a larger program.
     * If there are not enough profilers for all threads, only profilers.length threads
     * will be profiled. If there are more profilers than threads, the extra profilers
     * will be unused.
     *
     * Params:
     *
     * profilers = A slice of profilers to attach. The slice must not be modified after
     *             being passed. Profiler at profilers[0] will profile code running in
     *             the main thread.
     */
    void attachPerThreadProfilers(Profiler[] profilers) @safe pure nothrow @nogc
    {
        externalProfilers_ = profilers;
    }

    /** Get a copy of diagnostics from the last game update.
     *
     * Calling this during an update will return incomplete data.
     */
    Diagnostics diagnostics() @safe pure nothrow const @nogc { return diagnostics_; }

    /** Add a new entity, using components from specified prototype.
     *
     * The new entity will be added at the beginning of the next frame.
     *
     * Params:
     *
     * prototype = Prototype of the entity to add. Usually, the prototype will have to be
     *             casted to immutable before passed. Must exist without changes until the
     *             beginning of the next update. Can be safely deleted afterwards.
     *
     * Returns: ID of the new entity on success. A null ID if we've added more than
     *          Policy.maxNewEntitiesPerFrame new entities during one frame.
     */
    EntityID addEntity(ref immutable(EntityPrototype) prototype) @trusted nothrow
    {
        EntityID nothrowWrapper()
        {
            // Should be fast, assuming most of the time only 1 thread (SpawnerProcess)
            // adds entities. If slow, allow bulk adding with a struct that locks at
            // ctor/unlocks at dtor.
            auto entitiesToAdd = cast(EntitiesToAdd)entitiesToAdd_;
            synchronized(entitiesToAdd)
            {
                if(entitiesToAdd.prototypes.length == entitiesToAdd.prototypes.capacity)
                {
                    return EntityID.init;
                }

                auto id = EntityID(entitiesToAdd.nextEntityID++);
                entitiesToAdd.prototypes ~= tuple(&prototype, id);
                return id;
            }
        }

        return nothrowWrapper().assumeWontThrow();
    }

    /** Can be set to force more or less preallocation.
     *
     * Useful e.g. before loading a big map.
     *
     * Params:  mult = Multiplier for size of preallocations. Must be greater than 0.
     */
    void allocMult(const double mult) @safe pure nothrow
    {
        assert(mult > 0.0, "allocMult parameter set to 0 or less");
        allocMult_ = mult;
    }

    /** Execute a single frame/tick/time step of the game/simulation.
     *
     * Does all management needed between frames, and runs all registered processes on
     * matching entities once.
     *
     * This includes updating resource managers, swapping past/future state, forgetting
     * dead entities, creating entities added by addEntity, preallocation, etc.
     */
    void executeFrame() @trusted nothrow
    {
        auto zoneExecuteFrame = Zone(externalProfilers_[0], "EntityManager.executeFrame");
        frameDebug();
        updateResourceManagers();

        // Past entities from the previous frame may be longer or equal, but not shorter
        // than future entities from the previous frame: any dead entities from past were
        // not copied to future (any new entities were copied to both).
        assert(past_.entities.length >= future_.entities.length,
               "Less past than future entities in the previous frame. Past entities may "
               "be longer or equal, never shorter than future entities. The reason is "
               "that any dead entities from past are not copied to future (newly added "
               "entities are copied to both, so they don't affect relative lengths");

        // Get the past & future component/entity buffers for the new frame.
        GameStateT* newFuture = cast(GameStateT*)past_;
        GameStateT* newPast   = future_;

        newFuture.entities = cast(Entity[])newFuture.entities[0 .. newPast.entities.length];
        // Clear the future (former past) entities to help detect bugs.
        newFuture.entities[] = Entity.init;

        // Get the number of entities added this frame.
        auto entitiesToAdd     = cast(const(EntitiesToAdd))entitiesToAdd_;
        const addedEntityCount = entitiesToAdd.prototypes.length;

        // Copy alive past entities to future and create space for the newly added
        // entities in future.
        size_t futureEntityCount;
        {
            auto zone = Zone(externalProfilers_[0], "copy/add entities for next frame");

            futureEntityCount = copyLiveEntitiesToFuture(newPast, newFuture);
            newFuture.entities.length = futureEntityCount + addedEntityCount;
            newFuture.components.resetBuffers();
        }
        auto addedFutureEntities = newFuture.entities[futureEntityCount .. $];

        // Create space for the newly added entities in past.
        const pastEntityCount   = newPast.entities.length;
        newPast.entities.length = pastEntityCount + addedEntityCount;
        auto addedPastEntities  = newPast.entities[pastEntityCount .. $];

        // Preallocate future component buffer if needed.
        preallocateComponents(newFuture);

        // Inform the entity count buffers about a changed number of entities.
        {
            auto growZone = Zone(externalProfilers_[0], "growEntityCount");
            newPast.components.growEntityCount(newPast.entities.length);
            newFuture.components.growEntityCount(newFuture.entities.length);
        }

        // Add the new entities into the reserved entity/component space.
        addNewEntities(newPast.components, pastEntityCount,
                       addedPastEntities, addedFutureEntities);

        // Assign back to data members.
        future_ = newFuture;
        past_   = cast(immutable(GameStateT*))(newPast);

        executeProcesses();

        updateDiagnostics();
    }

    /** When used as an argument for a process() method of a Process, provides access to
     * the current entity handle and components of all past entities.
     *
     * See_Also: tharsis.entity.entityrange.EntityAccess
     */
    alias Context = EntityAccess!(typeof(this));

package:
    /** Get a resource handle without compile-time type information.
     *
     * Params:
     *
     * type       = Type of the resource. There must be a resource manager managing
     *              resources of this type.
     * descriptor = A void pointer to the descriptor of the resource. The actual type of
     *              the descriptor must be the Descriptor type of the resource type.
     *
     * Returns: A raw handle to the resource.
     */
    RawResourceHandle rawResourceHandle(TypeInfo type, void* descriptor) nothrow
    {
        foreach(manager; resourceManagers_) if(manager.managedResourceType is type)
        {
            return manager.rawHandle(descriptor);
        }
        assert(false, "No resource manager for type " ~ to!string(type));
    }

private:
    /** Register a Process.
     *
     * Params: process = Process to register. There may be at most 1 process writing any
     *                   single component type (specifying it as its FutureComponent).
     *                   The FutureComponent of the process must be registered with the
     *                   ComponentTypeManager passed to the EntityManager's constructor.
     *
     * TODO link to an process.rst once it exists
     */
    void registerProcess(P)(P process) @trusted nothrow
    {
        mixin validateProcess!P;

        auto registerZone = Zone(externalProfilers_[0], "EntityManager.registerProcess");
        // True if the Process does not write to any future component. Usually processes
        // that only read past components and produce some kind of output.
        enum noFuture = !hasFutureComponent!P;

        // All overloads of the process() method in the process.
        alias overloads = processOverloads!P;

        static if(!noFuture)
        {
            assert(!writtenComponentTypes_[P.FutureComponent.ComponentTypeID],
                   "Can't register 2 processes with one future component type");
            assert(componentTypeMgr_.areTypesRegistered!(P.FutureComponent),
                   "Registering a process with unregistered future component type " ~
                   P.FutureComponent.stringof);

            // This future component is now taken; no other process can write to it.
            writtenComponentTypes_[P.FutureComponent.ComponentTypeID] = true;
        }
        else
        {
        }

        // A function executing the process during one frame.
        //
        // Iterate past entities. If an entity has all past components in a signature of
        // any P.process() overload, call that overload, passing refs to those components
        // and a ref/ptr to a future component of type P.FutureComponent.
        //
        // Specific overloads have precedence over more general. For example, if there are
        // overloads process(A) and process(A, B), and an entity has components A and B,
        // the latter overload is called.
        static Diagnostics.Process runProcess(EntityManager self, P process) nothrow
        {
            Diagnostics.Process processDiagnostics;
            processDiagnostics.name = P.stringof;
            processDiagnostics.componentTypesRead = AllPastComponentTypes!P.length;
            // If the process has a 'preProcess' method, call it before processing any entities.
            static if(hasMember!(P, "preProcess")) { process.preProcess(); }

            // Iterate over all alive entities, executing the process on those that
            // match the process() methods of the Process.

            // Using a for instead of foreach because DMD insists on copying the range
            // in foreach for some reason, breaking the code.
            for(auto entityRange = EntityRange!(typeof(this), P)(self);
                !entityRange.empty(); entityRange.popFront())
            {
                static if(!noFuture)
                {
                    entityRange.setFutureComponentCount(0);
                }

                // Generates an if-else chain checking each overload, starting with the
                // most specific one.
                mixin(prioritizeProcessOverloads!P.map!(p => q{
                    if(entityRange.matchComponents!(%s))
                    {
                        ++processDiagnostics.processCalls;
                        self.callProcessMethod!(overloads[%s])(process, entityRange);
                    }
                }.format(p[0], p[1])).join("else ").outdent);
            }

            // If the process has a 'postProcess' method, call it after processing entities.
            static if(hasMember!(P, "postProcess")) { process.postProcess(); }

            return processDiagnostics;
        }

        // Add a wrapper for the process,
        processes_ ~= new ProcessWrapper!(P, Policy)(process, &runProcess);
    }

    // TODO a "locked" EntityManager state when no new stuff can be registered.
    /** Register specified resource manager.
     *
     * Once registered, components may refer to resources managed by this resource
     * manager, and the EntityManager will update it between frames.
     */
    void registerResourceManager(Manager)(Manager manager) @safe pure nothrow
        if(is(Manager : AbstractResourceManager))
    {
        assert(!resourceManagers_.canFind!(m => m.managedResourceType is
                                                manager.managedResourceType),
               "Can't register resource manager %s: a different manager already "
               "manages the same resource type");
        resourceManagers_ ~= manager;
    }

    /** Calls specified process() method of a Process.
     *
     * Params: F           = The process() method to call.
     *         process     = Process with the process() method.
     *         entityRange = Entity range to get the components to pass from.
     */
    static void callProcessMethod(alias F, P, ERange)(P process, ref ERange entityRange)
        nothrow
    {
        // True if the Process does not write to any future component. Usually these
        // processes read past components and produce some kind of output.
        enum noFuture   = !hasFutureComponent!P;
        alias PastTypes = PastComponentTypes!F;

        /* Generate a string with arguments to pass to a process() method.
         *
         * Mixed into the process() call at compile time. Should correctly handle
         * past/future component and EntityAccess arguments regardless of their order.
         *
         * Params: futureString = String to mix in to pass the future component/s
         *                        (should be the name of a variable defined where the
         *                        result is mixed in). Should be null if process()
         *                        writes no future component/s.
         */
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
                        assert(futureString !is null, "future component not specified");
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
            // Pass a slice by ref (checked by process validation). The process will
            // downsize the slice to the size it uses.
            P.FutureComponent[] future = entityRange.futureComponent();
            // For the assert below to check that process() doesn't do anything funky
            // like change the slice to point elsewhere.
            debug { auto old = future; }

            // Call the process() method.
            mixin(q{ process.process(%s); }.format(processArgs!"future"()));

            // For some reason, this is compiled in release mode; we use 'debug' to
            // explicitly make it debug-only.
            debug assert(old.ptr == future.ptr && old.length >= future.length,
                         "Process writing a future MultiComponent either changed the "
                         "passed future MultiComponent slice to point to another "
                         "location, or enlarged it");

            // The number of components written.
            const componentCount = cast(ComponentCount)future.length;
            entityRange.setFutureComponentCount(componentCount);
        }
        // If the future component is passed by pointer, process() may refuse to write a
        // future component.
        else static if(futureComponentByPointer!F)
        {
            // Pass pointer by reference; allows process() to set this to null.
            P.FutureComponent* future = entityRange.futureComponent();
            mixin(q{ process.process(%s); }.format(processArgs!"future"()));
            // If set to null, the future component was not written.
            if(future !is null) { entityRange.setFutureComponentCount(1); }
        }
        // Call a process() method that takes the future component by reference.
        else
        {
            mixin(q{process.process(%s);}
                  .format(processArgs!"*entityRange.futureComponent"()));
            entityRange.setFutureComponentCount(1);
        }
    }

    /// A shortcut to access component type information.
    const(ComponentTypeInfo[]) componentTypeInfo() @safe pure nothrow const
    {
        return componentTypeMgr_.componentTypeInfo;
    }

    ///////////////////////////////////////////
    /// BEGIN CODE CALLED BY executeFrame() ///
    ///////////////////////////////////////////

    /// Run all processes; called by executeFrame();
    void executeProcesses() @system nothrow
    {
        // We reset the process profilers each frame to avoid running out of space (for
        // now, we'll only use the profiling data from the last frame for scheduling).
        foreach(profiler; processProfilers_) { profiler.reset(); }

        auto totalProcZone = Zone(externalProfilers_[0], "EntityManager.executeProcesses()");

        scheduler_.updateSchedule!Policy(processes_, diagnostics_);

        import core.atomic;
        // Ensure any memory ops finish before finishing the new game update.
        atomicFence();

        // Start running Processes in ProcessThreads.
        foreach(thread; procThreads_) { thread.startUpdate(); }

        // The main thread (this thread) has index 0.
        executeProcessesOneThread(0);

        // Wait till all threads finish executing.
        {
            auto waitingZone = Zone(externalProfilers_[0], "waiting");
            while(procThreads_.canFind!(e => e.state == ProcessThread.State.Executing))
            {
                continue;
            }
        }
    }

    /** Run Processes assigned by the scheduler to the current thread.
     *
     * Called during executeProcesses(), from the main thread or a ProcessThread.
     *
     * Params:
     *
     * threadIdx = Index of the current thread (0 for the main thread, other for ProcessThreads)
     */
    void executeProcessesOneThread(uint threadIdx) @system nothrow
    {
        bool profilerExists   = externalProfilers_.length > threadIdx;
        auto externalProfiler = profilerExists ? externalProfilers_[threadIdx] : null;
        auto processProfiler  = processProfilers_[threadIdx];

        auto processesZone         = Zone(processProfiler, allProcessesZoneName);
        auto processesZoneExternal = Zone(externalProfiler, allProcessesZoneName);

        // Find all processes assigned to this thread (threadIdx).
        foreach(i, proc; processes_) if(scheduler_.processToThread(i) == threadIdx)
        {
            const name = proc.name;
            const nameCut = name[0 .. min(profilerNameCutoff, name.length)];
            auto procZoneExternal = Zone(externalProfiler, nameCut);
            auto procZone         = Zone(processProfiler, nameCut);

            proc.run(this);
        }
    }

    // Name used for the profiler Zone measuring time spent by all processes in a thread.
    //
    // Using __underscores__ to ensure it doesn't collide with zone name of any actual
    // process type.
    enum allProcessesZoneName = "__processes__";

    /// Update EntityManager diagnostics (after processes are run).
    void updateDiagnostics() @safe nothrow
    {
        const diagZone = Zone(externalProfilers_[0], "most diagnostics");

        diagnostics_ = Diagnostics.init;

        // Get process diagnostics.
        foreach(idx, process; processes_)
        {
            diagnostics_.processes[idx] = process.diagnostics;
        }

        // Get process execution durations from the profilers.
        foreach(prof; processProfilers_) foreach(zone; prof.profileData.zoneRange)
        {
            // Find the process (diagnostics) with name matching the zone info, and
            // set the duration.

            // startsWith(), because we cut off process names over profilerNameCutoff long.
            auto found = diagnostics_.processes[].find!(p => p.name.startsWith(zone.info));
            if(found.empty) { continue; }
            found.front.duration = zone.duration;
        }
        // Get the time spent executing processes in each thread this frame.
        foreach(threadIdx, prof; processProfilers_)
        {
            auto found = prof.profileData.zoneRange.find!(z => z.info == allProcessesZoneName)();
            assert(!found.empty, "Didn't find the 'all Processes in a thread' zone");
            diagnostics_.threads[threadIdx] = Diagnostics.Thread(found.front.duration);
        }

        const pastEntityCount = past_.entities.length;

        diagnostics_.pastEntityCount = pastEntityCount;
        diagnostics_.processCount    = processes_.length;
        diagnostics_.threadCount     = scheduler_.threadCount;

        // Accumulate (past) component type diagnostics.
        const(ComponentTypeInfo)[] compTypeInfo = componentTypeMgr_.componentTypeInfo;
        foreach(ushort typeID; 0 .. cast(ushort)compTypeInfo.length)
        {
            if(compTypeInfo[typeID].isNull) { continue; }

            // Get diagnostics for one component type.
            with(past_.components[typeID]) with(diagnostics_.componentTypes[typeID])
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


    /// Show any useful debugging info (warnings) before an update, and check update invariants.
    void frameDebug() @trusted nothrow
    {
        auto debugZone = Zone(externalProfilers_[0], "frameDebug");
        static void implementation(EntityManager self)
        {with(self){
            foreach(id; 0 .. maxBuiltinComponentTypes)
            {
                const(ComponentTypeInfo)* info = &componentTypeInfo[id];
                // If no such builtin component type exists, ignore.
                if(info.isNull) { continue; }
                assert(writtenComponentTypes_[id],
                       "No process writing builtin component type %s: please register "
                       "a process writing this component type (see "
                       "tharsis.defaults.copyprocess for a placeholder process)."
                       .format(info.name));
            }
            foreach(ref info; componentTypeInfo)
            {
                if(writtenComponentTypes_[info.id] || info.id == nullComponentTypeID)
                {
                    continue;
                }
                writefln("WARNING: No process writing component type %s: components of "
                        "this type will disappear after the first update.", info.name);
            }
        }}
        (cast(void function(EntityManager) nothrow)&implementation)(this);
    }

    /** Update every resource manager, allowing them to load resources.
     *
     * Part of the code executed between frames in executeFrame().
     */
    void updateResourceManagers() @safe nothrow
    {
        auto debugZone = Zone(externalProfilers_[0], "updateResourceManagers");
        foreach(resManager; resourceManagers_) { resManager.update(); }
    }

    /** Copy the surviving entities from past to future entity buffer.
     *
     * Part of the code executed between frames in executeFrame().
     *
     * Params: past   = New past, former future state.
     *         future = New future, former past state. future.entities must be exactly
     *                  as long as past.entities. Surviving entities will be copied here.
     *
     * Returns: The number of surviving entities written to futureEntities.
     */
    static size_t copyLiveEntitiesToFuture(const(GameStateT)* past, GameStateT* future)
        @trusted pure nothrow
    {
        assert(past.entities.length == future.entities.length,
               "Past/future entity counts do not match");

        // Get the past LifeComponents.
        enum lifeID            = LifeComponent.ComponentTypeID;
        auto rawLifeComponents = past.components[lifeID].buffer.committedComponentSpace;
        auto lifeComponents    = cast(immutable(LifeComponent)[])rawLifeComponents;

        // Copy the alive entities to the future and count them.
        size_t aliveEntities = 0;
        foreach(i, pastEntity; past.entities) if(lifeComponents[i].alive)
        {
            future.entities[aliveEntities++] = pastEntity;
        }
        return aliveEntities;
    }

    /** Preallocate space in component buffers.
     *
     * Part of the code executed between frames in executeFrame().
     *
     * Used to prealloc space for future components to minimize allocations during update.
     *
     * Params: state = Game state (past or future) to preallocate space for.
     */
    void preallocateComponents(GameStateT* state) @safe nothrow
    {
        auto preallocZone = Zone(externalProfilers_[0], "preallocateComponents");
        // Preallocate space for components based on hints in the Policy and component
        // type info.

        const entityCount    = state.entities.length;
        const minAllEntities = cast(size_t)(Policy.minComponentPerEntityPrealloc * entityCount);
        enum baseMinimum     = Policy.minComponentPrealloc;

        foreach(ref info; componentTypeInfo) if(!info.isNull)
        {
            // Component type specific minimums.
            const minimum             = max(baseMinimum, info.minPrealloc);
            const specificAllEntities = cast(size_t)(info.minPreallocPerEntity * entityCount);
            const allEntities         = max(minAllEntities, specificAllEntities);
            const prealloc            = cast(size_t)(allocMult_ * max(minimum, allEntities));
            state.components[info.id].buffer.reserveComponentSpace(prealloc);
        }
    }

    /** Add newly created entities (from the entitiesToAdd_ data member).
     *
     * Part of the code executed between frames in executeFrame().
     *
     * Params:
     *
     * target          = Past component buffers to add components of the added entities
     *                   to. We're adding entities created during the previous frame; the
     *                   next frame will see them as past state.
     * baseEntityCount = The number of past entities (before the new entities are added).
     * targetPast      = Past entities to add the newly created entities to. Must have
     *                   enough space for all entities in entitiesToAdd_.
     * targetFuture    = Future entities to add the newly created entities to. (They need
     *                   to be added for processes to run; processes running during the
     *                   next frame will then decide whether or not they will continue to
     *                   live). Must have enough space for all entities in entitiesToAdd_.
     */
    void addNewEntities(ref ComponentStateT target, const size_t baseEntityCount,
                        Entity[] targetPast, Entity[] targetFuture)
        @trusted nothrow
    {
        auto addZone = Zone(externalProfilers_[0], "addNewEntities");

        auto entitiesToAdd = cast(EntitiesToAdd)entitiesToAdd_;
        const(ComponentTypeInfo)[] compTypeInfo = componentTypeMgr_.componentTypeInfo;
        foreach(index, pair; entitiesToAdd.prototypes)
        {
            immutable(EntityPrototype)* prototype = pair[0];

            // Component counts of each component type for this entity.
            ComponentCount[maxComponentTypes!Policy] componentCounts;

            // Copy components from the prototype to component buffers.
            foreach(const rawComponent; prototype.constComponentRange(compTypeInfo))
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

    /////////////////////////////////////////
    /// END CODE CALLED BY executeFrame() ///
    /////////////////////////////////////////
}
