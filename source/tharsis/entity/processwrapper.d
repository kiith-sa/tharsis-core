//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// A wrapper that handles execution of a Process.
module tharsis.entity.processwrapper;


import std.algorithm;

import tharsis.entity.entitymanager;

// TODO: Allow processes to specify the maximum number of skipped updates
//       (default 0), as well as CPU overhead hints
//       (using an enum (trivial, cheap, medium, expensive, bottleneck))


/// Abstract parent class to allow storing all process wrappers in a single array.
class AbstractProcessWrapper(Policy)
{
private:
    /// Name of the process.
    string name_;

    /// If not uint.max, this process must run in thead with index boundToThread_ % threadCount.
    uint boundToThread_ = uint.max;

    /// Process diagnostics, updated by the last run() call.
    ProcessDiagnostics diagnostics_;

    import tharsis.prof;
    /// Internal profiler used to profile runtime of this process.
    Profiler profiler_;

    /// Storage used by profiler_ to record profile data to.
    ubyte[] profilerStorage_;

public:
    /// Alias for diagnostics info about a process run.
    alias ProcessDiagnostics = EntityManager!Policy.Diagnostics.Process;

    /** Runs the process on all matching entities from specified entity manager.
     *
     * Updates diagnostics (e.g. benchmarking) info about the process run.
     *
     * Params:
     *
     * entities    = Entity manager used to read entities, the "self" parameter for the
     *               generated runProcess() function.
     * extProfiler = External profiler, if provided by the user.
     */
    void run(EntityManager!Policy entities, Profiler extProfiler) nothrow
    {
        assert(false, "DMD (2065) bug workaround - should never happen");
    }

    /// Construct the process wrapper. Initializes the process profiler
    this() @trusted nothrow
    {
        // For now, assume 32kiB is enough for the Process. (TODO) Once we finish TimeStep
        // replacement in Tharsis.prof, even 4k or less (static buffer) will be enough.
        import core.stdc.stdlib;
        profilerStorage_ = (cast(ubyte*)malloc(32 * 1024))[0 .. 32 * 1024];
        profiler_        = new Profiler(profilerStorage_);
    }

    /// Destroy the process wrapper. Must be called.
    ~this() nothrow
    {
        import core.stdc.stdlib;
        free(profilerStorage_.ptr);
    }

    /// Get name of the wrapped process.
    string name() @safe pure nothrow const @nogc { return name_; }

    /// Get process diagnostics updated by the last run() call.
    ref const(ProcessDiagnostics) diagnostics() @safe pure nothrow const @nogc 
    {
        return diagnostics_;
    }

    /// Get the internal profiler (only has one zone - process execution time).
    const(Profiler) profiler() @safe pure nothrow const @nogc
    {
        return profiler_;
    }

    /** If the process must run in a specific thread, returns its index, otherwise uint.max.
     *
     * Note: the actual index of the thread the process will run in is
     *       $(D boundToThread % threadCount), where $(D threadCount) is the number of
     *       threads used by EntityManager.
     */
    uint boundToThread() @safe pure nothrow const @nogc
    {
        return boundToThread_;
    }
}

/// Wraps a process of a concrete type.
class ProcessWrapper(Process, Policy) : AbstractProcessWrapper!Policy
{
private:
    /// The wrapped process.
    Process process_;

    /// A generated function that runs the process on all matching entities.
    ProcessFunction runProcess_;

public:
    /** A generated function that runs the process on all matching entities.
     *
     * The EntityManager parameter provides the entities to process; the Process parameter
     * is the process who's process() method/s will be called.
     *
     * Can be changed into delegate if needed, but try to keep it a function.
     */
    alias ProcessDiagnostics function(EntityManager!Policy, Process) nothrow ProcessFunction;

    /** Construct a ProcessWrapper.
     *
     * Params: process    = Process to wrap.
     *         runProcess = Function that, passed the entity manager and the process, will
     *                      run process all entities with components matching the process.
     */
    this(Process process, ProcessFunction runProcess) nothrow
    {
        process_    = process;
        runProcess_ = runProcess;
        name_       = Process.stringof;
        import std.traits;
        // The actual thread this runs in is boundToThread % threadCount
        static if(hasMember!(Process, "boundToThread"))
        {
            boundToThread_ = Process.boundToThread;
        }
        super();
    }

    override void run(EntityManager!Policy entities, Profiler extProfiler) nothrow
    {
        profiler_.reset();
        const nameCut = name[0 .. min(Policy.profilerNameCutoff, name.length)];
        auto zone = Zone(profiler_, nameCut);
        diagnostics_ = runProcess_(entities, process_);
    }
}
