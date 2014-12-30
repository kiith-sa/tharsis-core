//          Copyright Ferdindand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Types used to store diagnostics info (e.g. for performance measurements).
module tharsis.entity.diagnostics;


import std.algorithm;
import std.exception;


import tharsis.entity.entitypolicy;



/// Diagnostics info about a Tharsis [process](../concepts/process.html).
struct ProcessDiagnostics
{
    /** Name of the process.
     *
     * If null, this Process struct is unused and doesn't store diagnostics for any
     * process.
     */
    string name;
    /** Number of calls to the [process()](../concepts/process.html#process-method)
     * method/s of the Process during the game update.
     *
     * A Process may have multiple process() methods, but at most one of them will be
     * called for one entity.
     */
    size_t processCalls;
    /** Number of past component types read by the process.
     *
     * This is the number of different past component types read by *all* process()
     * methods of the Process.
     */
    size_t componentTypesRead;

    /// Time this process spent executing this frame in hectonanoseconds.
    ulong duration;
}

/// Diagnostics info for Scheduler.
struct SchedulerDiagnostics
{
    /// Name of the scheduling algorithm used.
    string schedulingAlgorithm;

    /// Did the algorithm produce approximate (not guaranteed to be optimal) schedule?
    bool approximate;

    /// Estimated time of the next frame in hectonanoseconds.
    ulong estimatedFrameTime;

    /// Time estimator diagnostics (duh).
    TimeEstimatorDiagnostics timeEstimator;
}

/** Diagnostics info for the Scheduler's TimeEstimator.
 *
 * The *underestimate* values measure how much did the estimator underestimate the
 * execution time of a process. Positive underestimate means the process took longer than
 * estimated, negative means it took less time.
 */
struct TimeEstimatorDiagnostics 
{
    /// Absolute total time estimate error for all processes in hectonanoseconds.
    ulong totalProcessError;
    /// Absolute total *underestimate* for all processes in hectonanoseconds.
    long totalProcessUnderestimate;
    /// The max (worst) underestimate of all processes in hectonanoseconds.
    long maxProcessUnderestimate = long.min;

    /// Average estimate error *ratio* (estimate error relative to process run time).
    double averageProcessErrorRatio = 0.0;
    /// Average *underestimate* ratio.
    double averageProcessUnderestimateRatio = 0.0;
    /** The max (worst) underestimate ratio.
     *
     * Note that a high ratio doesn't necessarily mean the process took long; for the
     * longest *absolute* underestimate see maxProcessUnderestimate.
     */
    double maxProcessUnderestimateRatio = cast(double)int.min;
}

/// Diagnostics info for EntityManager.
struct EntityManagerDiagnostics(Policy)
{
    /// Diagnostics info about components of one component type.
    struct ComponentType
    {
        /** Name of the component type.
         *
         * If `null`, this ComponentType struct is unused and doesn't store diagnostics 
         * for any component type.
         */
        string name;
        /// Number of past components of this type in the entity manager.
        size_t pastComponentCount;
        /// Bytes allocated for past components of this type in the entity manager.
        size_t pastMemoryAllocated;
        /// Bytes actually used for past components of this type in the entity manager.
        size_t pastMemoryUsed;

        /// Is this a *null* struct that doesn't store valid data?
        bool isNull() @safe pure nothrow const @nogc { return name is null; }
    }

    /// Diagnostics info about a thread.
    struct Thread 
    {
        /** Time this thread spent executing processes this frame in hectonanoseconds.
         */
        ulong processesDuration;
    }

    /// Number of entities in past state.
    size_t pastEntityCount;

    /// Number of registered processes.
    size_t processCount;

    /// Number of process execution threads (including the main thread).
    size_t threadCount;

    /** Diagnostics for individual component types.
     *
     * Note:
     *
     * Not all entries in this array match existing component types. If 
     * `componentTypes[i].isNull == true`, there is no component type with ID $(D i)
     * and the curresponding entry is invalid.
     */
    ComponentType[maxComponentTypes!Policy] componentTypes;

    // Stores process diagnostics (accessed through a slice with processes()).
    // There may be more processes than this but it's highly unlikely.
    ProcessDiagnostics[Policy.maxProcesses] processesStorage;

    /// Get diagnostics for all used [Processes](../concepts/process.html).
    inout(ProcessDiagnostics)[] processes() @safe pure nothrow inout @nogc
    {
        return processesStorage[0 .. processCount];
    }

    Thread[processesStorage.length] threadStorage;
    /// Get diagnostics for all threads used to run Processes.
    inout(Thread)[] threads() @safe pure nothrow inout @nogc
    {
        return threadStorage[0 .. threadCount];
    }

    /// Diagnostics for the scheduler.
    SchedulerDiagnostics scheduler;

    // TODO resource manager diagnostics 
    // (memory allocated/used by this manager, new/loading/loaded/loadfailed counts)
    // 2014-08-28

    /// Get the total number of past components of any type.
    size_t pastComponentsTotal() @safe pure nothrow const
    {
        return componentTypes[].map!(a => a.pastComponentCount)
                               .reduce!((a, b) => a + b).assumeWontThrow;
    }

    /** Get the average number of past components of specified type in an entity.
     *
     * Params:
     *
     * typeID = Type ID of the component type. **Must be a type ID of a registered component
     *          type.**
     */
    double pastComponentsPerEntity(ushort typeID)
        @safe pure nothrow const @nogc
    {
        assert(!componentTypes[typeID].isNull,
               "Trying to get pastComponentsPerEntity for an unknown component type");
        return componentTypes[typeID].pastComponentCount / cast(double)pastEntityCount;
    }

    /// Get the average number of past components of all types in an entity.
    double pastComponentsPerEntityTotal() @safe pure nothrow const
    {
        return pastComponentsTotal / cast(double)pastEntityCount;
    }

    /// Get the total number of calls to [process()](../concepts/process.html#process-method)
    /// methods of all Processes.
    size_t processCallsTotal() @safe pure nothrow const
    {
        return processes[].map!(a => a.processCalls).reduce!((a, b) => a + b).assumeWontThrow;
    }

    /// Get the total (summed) duration of all processes in all threads.
    ulong processDurationTotal() @safe pure nothrow const
    {
        return processes[].map!(a => a.duration).reduce!((a, b) => a + b).assumeWontThrow;
    }

    /// Get the average duration of a process.
    ulong processDurationAverage() @safe pure nothrow const
    {
        return processDurationTotal / processCount;
    }

    /** Get the average number of process() calls per entity.
     *
     * Can also be interpreted as the average number of processes that match any single
     * entity.
     */
    double processCallsPerEntity() @safe pure nothrow const
    {
        return processCallsTotal / cast(double)pastEntityCount;
    }

    /// Get the total memory allocated for past components in bytes.
    size_t pastMemoryAllocatedTotal() @safe pure nothrow const
    {
        return componentTypes[].map!(a => a.pastMemoryAllocated)
                               .reduce!((a, b) => a + b).assumeWontThrow;
    }

    /// Get the total memory used by past components in bytes.
    size_t pastMemoryUsedTotal() @safe pure nothrow const
    {
        return componentTypes[].map!(a => a.pastMemoryUsed)
                               .reduce!((a, b) => a + b).assumeWontThrow;
    }

    /// Get the average memory used by an entity in bytes.
    double pastMemoryUsedPerEntity() @safe pure nothrow const
    {
        return pastMemoryUsedTotal / cast(double)pastEntityCount;
    }

    /// Get the number of past component types read by a Process on average.
    double componentTypesReadPerProcess() @safe pure nothrow const
    {
        return processes[].map!(a => a.componentTypesRead)
                          .reduce!((a, b) => a + b).assumeWontThrow 
                          / cast(double)processCount;
    }
}
