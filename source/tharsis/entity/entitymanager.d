//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//          http://www.boost.org/LICENSE_1_0.txt)

//    (See accompanying file LICENSE_1_0.txt or copy at
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
    static class ProcessThread
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
            // The thread is stopped, or never ran in the first place.
            Stopped,
        }

    private:
        // The thread itself.
        Thread thread_;

        // Using atomic *stores* to set state_ but don't use atomic loads to read it:
        // The value won't get 'teared' since it's 1 byte.

        // Current state of the thread. Use atomic stores to write, normal reads to read.
        shared(State) state_ = State.Stopped;

        // The entity manager (called self_ because this is essentially EntityManager code).
        EntityManager self_;

        // Index of this thread (main thread is 0, first external thread 1, next 2, etc.)
        uint threadIdx_;

        // Name of the thread (for profiling/debugging).
        string threadName_;

        // External profiler (if any) attached by the user to profile this thread.
        //
        // See_Also: EntityManager.attachPerThreadProfilers()
        Profiler profiler_;

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
            self_       = self;
            threadIdx_  = threadIdx;
            threadName_ = "Tharsis ExecuteThread %s".format(threadIdx_).assumeWontThrow;
        }

        /// Destroy the thread.
        ~this()
        {
            // .destroy(thread_);
            assert(thread_ is null, "Thread must be stopped before being destroyed");
        }

        /// Attach an external profiler to profile this thread.
        void profiler(Profiler rhs) @system nothrow
        {
            assert(!isRunning, "Trying to attach a profiler while the thread is running");
            profiler_ = rhs;
        }

        /// Get the current state of the thread.
        final State state() @system pure nothrow @nogc { return cast(State)state_; }

        /// Call when waiting so the OS can use the CPU core for something else.
        void yieldToOS() @system nothrow
        {
            assert(thread_ !is null, "yieldToOS called when thread stopped");
            try 
            {
                // thread_.yield();
                thread_.sleep(dur!"msecs"(0)); 
            }
            // TODO: log this, eventually (despiker eventEvent?) 2014-09-17
            catch(Exception e) { }  // ignore, resulting in a hot loop replacing sleep
        }

        /// Is the thread running right now?
        bool isRunning() @system nothrow
        {
            return !(thread_ is null) && thread_.isRunning;
        }

        /** Create and start the thread itself.
         *
         * Throws:
         *
         * core.thread.ThreadException on failure to start the thread.
         */
        void start() @system 
        {
            assert(state_ == State.Stopped, "Can't start a thread that is not stopped");
            state_  = state_.Waiting;
            thread_ = new Thread(&run);
            thread_.start();
        }

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

            try
            {
                scope(exit) 
                {
                    atomicStore(state_, State.Stopped); 
                    .destroy(thread_);
                }
                thread_.join();
            }
            catch(Throwable e)
            {
                // TODO: Logging 2014-09-17
                import std.stdio;
                writeln("EntityManager thread terminated with an error:").assumeWontThrow;
                writeln(e).assumeWontThrow;
            }
            thread_ = null;
        }

        /** Start executing processes in a game update. Should be called only by EntityManager.
         *
         * Can only be called when the thread is in Waiting state.
         */
        final void startUpdate() @system nothrow
        {
            assert(thread_ !is null, "startUpdate called when thread stopped");
            assert(isRunning, "Trying to startUpdate() in a thread that is not running");
            assert(state == State.Waiting, "Trying to start an update on an ProcessThread "
                                           "that is either executing or is stopping");
            atomicStore(state_, State.Executing);
        }

        /// Code that runs in the ProcessThread.
        void run() @system nothrow
        {
            assert(thread_ !is null, "startUpdate called when thread stopped");
            ulong frameIdx = 0;
            // Note:
            // Can't have any profiler events while Waiting because user code may decide
            // to read profiler data between frames.
            for(;;) final switch(state)
            {
                case State.Waiting:
                    bool shouldSleep = true;
                    // Wait for the next game update.
                    // No profiling so the user can access the profiler between frames.
                    while(state == State.Waiting)
                    {
                        // We need to give the OS some time to do other work... if we hog 
                        // all cores the OS will stop our threads at inconvenient times.
                        yieldToOS();
                        continue;
                    }
                    break;
                case State.Executing:
                    {
                        // scope(exit) ensures the state is set even if we're crashing
                        // with a Throwable (to avoid EntityManager waiting forever).
                        scope(exit) { atomicStore(state_, State.Waiting); }

                        {
                            auto frameZone = Zone(profiler_, "frame");
                            self_.executeProcessesOneThread(threadIdx_, profiler_);
                        }
                        ++frameIdx;
                        // Ensure any memory ops finish before finishing a game update.
                        atomicFence();
                    }
                    break;
                case State.Stopping:
                    // return, finishing the thread.
                    return;
                case State.Stopped:
                    assert(false, "run() still running when the thread is Stopped");
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
        /// ID of the next entity that will be created.
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

    /// Have the process threads been started?
    bool threadsStarted_ = false;

    /// Diagnostics data (how many components of which type, etc).
    Diagnostics diagnostics_;

    /// Profiler (if any) attached to the main thread by attachPerThreadProfilers().
    Profiler profilerMainThread_ = null;

public:
    /** Construct an EntityManager using component types registered in a ComponentTypeManager.
     *
     * Note: startThreads() must be called before executing any game updates (frames).
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
        // Construct process threads.
        // 0 is the main thread, so we only need to add threads other than 0.
        foreach(threadIdx; 1 .. scheduler_.threadCount)
        {
            procThreads_ ~= new ProcessThread(this, cast(uint)threadIdx);
        }

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

    /** Start executing EntityManager in multiple threads.
     *
     * Throws:
     *
     * core.thread.ThreadException on failure to start the threads..
     */
    void startThreads() @trusted
    {
        // Start the process threads. This is the place where the user can handle any
        // failure to start the threads. updateThreads() assumes starting threads to be
        // safe.
        foreach(thread; procThreads_) { thread.start(); }
        threadsStarted_ = true;
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
        auto zoneDtor = Zone(profilerMainThread_, "EntityManager.destroy");
        .destroy(cast(EntitiesToAdd)entitiesToAdd_);
        if(clearResources) foreach(manager; resourceManagers_)
        {
            manager.clear();
        }

        // Tell all process threads to stop and then wait to join them.
        foreach(thread; procThreads_) if(thread.state != ProcessThread.State.Stopped)
        {
            thread.stop(); 
        }

        import core.stdc.stdlib: free;
        .destroy(scheduler_);
        foreach(wrapper; processes_) { .destroy(wrapper); }
    }

    /** Attach multiple Profilers, each of which will profile a single thread.
     *
     * Can only be called before startThreads().
     *
     * Allows to profile Tharsis execution as a part of a larger program. If there are not
     * enough profilers for all threads, only profilers.length threads will be profiled.
     * If there are more profilers than threads, the extra profilers will be unused.
     *
     * Params:
     *
     * profilers = Profilers to attach. Profiler at profilers[0] will profile code running
     *             in the main thread. $(B Note: ) attached profilers must not be modified
     *             until the EntityManager.destroy() (which stops the threads) is called.
     */
    void attachPerThreadProfilers(Profiler[] profilers) @trusted nothrow
    {
        assert(!threadsStarted_, "Trying to attach profilers after starting threads");
        if(profilers.empty) { return; }
        profilerMainThread_ = profilers.front;
        foreach(idx, prof; profilers[1 .. $]) { procThreads_[idx].profiler = prof; }
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
        assert(threadsStarted_, "startThreads() must be called before executeFrame()");

        auto zoneExecuteFrame = Zone(profilerMainThread_, "EntityManager.executeFrame");
        frameDebug();
        updateResourceManagers();

        // Past entities from the previous frame may be longer or equal, but not shorter
        // than future entities.
        assert(past_.entities.length >= future_.entities.length,
               "Less past than future entities in previous frame. Past entities may be "
               "longer or equal, never shorter than future entities: any dead entities "
               "from past are not copied to future (newly added entities are copied to "
               "both, so they don't affect relative lengths");

        // Get the past & future component/entity buffers for the new frame.
        GameStateT* newFuture = cast(GameStateT*)past_;
        GameStateT* newPast   = future_;

        // Copy alive past entities to future.
        {
            auto zone = Zone(profilerMainThread_, "copy entities from the past update");
            newPast.copyLiveEntitiesToFuture(*newFuture);
        }
        // Create space for the newly added entities.
        {
            auto zone = Zone(profilerMainThread_, "add new entities without initializing");
            const addedEntityCount = (cast(EntitiesToAdd)entitiesToAdd_).prototypes.length;
            newPast.addNewEntitiesNoInit(addedEntityCount, profilerMainThread_);
            newFuture.addNewEntitiesNoInit(addedEntityCount, profilerMainThread_);
        }
        // Preallocate future component buffer if needed.
        {
            auto zone = Zone(profilerMainThread_, "preallocate components");
            newFuture.preallocateComponents(allocMult_, componentTypeMgr_);
        }
        // Add the new entities into the reserved entity/component space.
        {
            auto zone = Zone(profilerMainThread_, "init new entities");
            initNewEntities((cast(EntitiesToAdd)entitiesToAdd_).prototypes,
                            componentTypeMgr_, *newPast, *newFuture);
            // Clear to reuse during the next frame.
            (cast(EntitiesToAdd)entitiesToAdd_).prototypes.clear();
        }

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

        auto registerZone = Zone(profilerMainThread_, "EntityManager.registerProcess");
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
        //
        // Params: self           = The entity manager.
        //         process        = The process being executed.
        //         threadProfiler = Profiler for this thread, if attached with
        //                          attachPerThreadProfilers().
        static ProcessDiagnostics runProcess
            (EntityManager self, P process, Profiler threadProfiler) nothrow
        {
            ProcessDiagnostics processDiagnostics;
            processDiagnostics.name = P.stringof;
            processDiagnostics.componentTypesRead = AllPastComponentTypes!P.length;
            // If the process has a 'preProcess' method, call it before processing any entities.
            static if(hasMember!(P, "preProcess"))
            {
                alias params = ParameterTypeTuple!(process.preProcess);
                static if(params.length == 0)
                {
                    process.preProcess();
                }
                else
                {
                    static assert(params.length == 1 && is(params[0] == Profiler),
                                  "preProcess() method of a process must either have no "
                                  "parameters, or exactly one Profiler parameter "
                                  "(for one of the thread profilers attached by the "
                                  "EntityManager.attachPerThreadProfilers())");
                    process.preProcess(threadProfiler);
                }
            }

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
         * Params: futureStr = String to mix in to pass the future component/s (should be
         *                     the name of a variable defined where the mixed in). Should
         *                     be null if process() writes no future component/s.
         */
        string processArgs(string futureStr = null)()
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
                        assert(futureStr !is null, "future component not specified");
                        parts ~= futureStr;
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


    /// Ensure only the threads with processes scheduled to them will run.
    void updateThreads() @trusted nothrow
    {
        foreach(idx, thread; procThreads_) with(ProcessThread.State)
        {
            // If a thread is idle for this many frames, we can stop it.
            enum idleFramesTillStop = 4;
            // 0 is the main thread, which is always running
            const threadIdx = idx + 1;
            const state = thread.state;
            if(state != Stopped && scheduler_.idleFrames(threadIdx) >= idleFramesTillStop)
            {
                thread.stop();
            }
            else if(state == Stopped && scheduler_.idleFrames(threadIdx) == 0)
            {
                thread.start().assumeWontThrow;
            }
        }
    }

    /// Run all processes; called by executeFrame();
    void executeProcesses() @system nothrow
    {
        auto totalProcZone = Zone(profilerMainThread_, "EntityManager.executeProcesses()");

        {
            auto schedulingZone = Zone(profilerMainThread_, "scheduling");
            scheduler_.updateSchedule!Policy(processes_, diagnostics_, profilerMainThread_);
        }

        import core.atomic;
        updateThreads();

        // Ensure any memory ops finish before finishing the new game update.
        atomicFence();

        // Start running Processes in ProcessThreads.
        foreach(thread; procThreads_) if(thread.state != ProcessThread.State.Stopped)
        {
            thread.startUpdate(); 
        }

        // The main thread (this thread) has index 0.
        executeProcessesOneThread(0, profilerMainThread_);

        // Wait till all threads finish executing.
        {
            auto waitingZone = Zone(profilerMainThread_, "waiting");
            bool shouldSleep = true;

            while(procThreads_.canFind!(e => e.state == ProcessThread.State.Executing))
            {
                try if(shouldSleep)
                {
                    Thread.sleep(dur!"msecs"(0));
                }
                catch(Exception e)
                {
                    // ignore, will wait in hot loop if we can't sleep
                }

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
     * profiler  = Profiler to profile this thread with, if any is attached.
     */
    void executeProcessesOneThread(uint threadIdx, Profiler profiler)
        @system nothrow
    {
        auto processesZoneExternal = Zone(profiler, allProcessesZoneName);

        // Find all processes assigned to this thread (threadIdx).
        foreach(i, proc; processes_) if(scheduler_.processToThread(i) == threadIdx)
        {
            const name = proc.name;
            const nameCut = name[0 .. min(Policy.profilerNameCutoff, name.length)];
            auto procZoneExternal = Zone(profiler, nameCut);

            proc.run(this, profiler);
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
        auto diagZone = Zone(profilerMainThread_, "updateDiagnostics()");

        diagnostics_ = Diagnostics.init;

        {
            auto procDiagZone = Zone(profilerMainThread_, "process diagnostics");

            // Get process diagnostics.
            foreach(idx, process; processes_)
            {
                diagnostics_.processes[idx] = process.diagnostics;
            }

            // Get process execution durations from the processes' internal profilers.
            foreach(idx, process; processes_)
            {
                auto zones = process.profiler.profileData.zoneRange;
                import std.range;
                assert(zones.walkLength == 1,
                        "A process profiler must have exactly 1 zone - process execution time");
                const duration = zones.front.duration;
                diagnostics_.processes[idx].duration = duration;
                const threadIdx = scheduler_.processToThread(idx);

                diagnostics_.threads[threadIdx].processesDuration += duration;
            }

            diagnostics_.processCount = processes_.length;
            diagnostics_.threadCount  = scheduler_.threadCount;
        }

        {
            auto stateDiagZone = Zone(profilerMainThread_, "GameState.updateDiagnostics()");
            past_.updateDiagnostics(diagnostics_, componentTypeMgr_);
        }

        diagnostics_.scheduler = scheduler_.diagnostics;
    }


    /// Show any useful debugging info (warnings) before an update, and check update invariants.
    void frameDebug() @trusted nothrow
    {
        auto debugZone = Zone(profilerMainThread_, "frameDebug");

        foreach(id; 0 .. maxBuiltinComponentTypes)
        {
            const(ComponentTypeInfo)* info = &componentTypeInfo[id];
            // If no such builtin component type exists, ignore.
            if(info.isNull) { continue; }
            assert(writtenComponentTypes_[id],
                   "No process writing builtin component type %s: register a process "
                   "writing this component type (see tharsis.defaults.copyprocess for "
                   "a placeholder).".format(info.name).assumeWontThrow);
        }
        // If no process writes a component type, print a warning.
        foreach(ref info; componentTypeInfo)
        {
            if(writtenComponentTypes_[info.id] || info.id == nullComponentTypeID)
            {
                continue;
            }
            writefln("WARNING: No process writing component type %s: components of this "
                     " type will disappear after the first update.", info.name)
                     .assumeWontThrow;
        }
    }

    /** Update every resource manager, allowing them to load resources.
     *
     * Part of the code executed between frames in executeFrame().
     */
    void updateResourceManagers() @safe nothrow
    {
        auto resourceZone = Zone(profilerMainThread_, "updateResourceManagers");
        foreach(resManager; resourceManagers_) { resManager.update(); }
    }

    /////////////////////////////////////////
    /// END CODE CALLED BY executeFrame() ///
    /////////////////////////////////////////
}
