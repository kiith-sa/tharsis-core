//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// A wrapper that handles execution of a Process.
module tharsis.entity.processwrapper;


import std.algorithm;

import tharsis.entity.entitymanager;

package:

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
    import tharsis.entity.diagnostics: ProcessDiagnostics;

    /** Runs the process on all matching entities from specified entity manager.
     *
     * Updates diagnostics (e.g. benchmarking) info about the process run.
     *
     * Params:
     *
     * entities    = Entity manager used to get entities; the "self" parameter for the
     *               generated runProcess() function.
     * extProfiler = External profiler, if provided by the user.
     */
    void run(EntityManager!Policy entities, Profiler extProfiler) nothrow
    {
        assert(false, "DMD (2065) bug workaround - should never happen");
    }

    /// Construct the process wrapper. Initializes the process profiler.
    this() @trusted nothrow
    {
        // 4kiB should be enough (profiler_ should only have one zone).
        import core.stdc.stdlib;
        profilerStorage_ = (cast(ubyte*)malloc(4 * 1024))[0 .. 4 * 1024];
        profiler_        = new Profiler(profilerStorage_);
    }

    /// Destroy the process wrapper. Must be called.
    ~this() nothrow @nogc
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

    /** Get index of the thread the process is bound to if bound, or uint.max otherwise.
     *
     * Note: the actual thread (index) the process will run in is
     *       $(D boundToThread % threadCount), where $(D threadCount) is the number of
     *       threads used.
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
     * The EntityManager param provides entities to the process; the Process param is the
     * process who's process() method/s will be called. The Profiler parame is an external
     * profiler for the thread the Process runs in, if attached through
     * $(D EntitityManager.attachPerThreadProfilers()).
     *
     * Can be changed into delegate if needed, but try to keep it a function.
     */
    alias ProcessDiagnostics function(EntityManager!Policy, Process, Profiler) nothrow ProcessFunction;

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
        diagnostics_ = runProcess_(entities, process_, extProfiler);
    }
}


import std.algorithm: join;
import std.string: format;
import std.traits;

import tharsis.entity.processtypeinfo;
import tharsis.entity.componenttypeinfo;

/** Calls specified process() method of a Process.
 *
 * Params: F           = The process() method to call.
 *         process     = Process with the process() method.
 *         entityRange = Entity range to get the components to pass from.
 */
void callProcessMethod(alias F, P, ERange)(P process, ref ERange entityRange) nothrow
{
    alias ComponentCount = ERange.Policy.ComponentCount;

    // True if the Process does not write to any future component. Usually these processes
    // read past components and produce some kind of output.
    enum noFuture   = !hasFutureComponent!P;
    alias PastTypes = PastComponentTypes!F;

    /* Generate a string with arguments to pass to a process() method.
     *
     * Mixed into the process() call at compile time. Should correctly handle past/future
     * component and EntityAccess arguments regardless of their order.
     *
     * Params: futureStr = String to mix in to pass future component/s (should be the name
     *                     of a variable defined where the mixed in). Should be null if
     *                     process() writes no future component/s.
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
                    parts ~= q{entityRange.pastComponent!(PastTypes[%s])}.format(pastIndex);
                    ++pastIndex;
                }
            }
            else static assert(false, "Unsupported process() parameter: " ~ Param.stringof);
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
        // Pass a slice by ref (checked by process validation). The process will downsize
        // the slice to the size it uses.
        P.FutureComponent[] future = entityRange.futureComponent();
        // For the assert below to check that process() doesn't do anything funky like
        // change the slice to point elsewhere.
        debug { auto old = future; }

        // Call the process() method.
        mixin(q{ process.process(%s); }.format(processArgs!"future"()));

        // For some reason, this is compiled in release mode; we use 'debug' to explicitly
        // make it debug-only.
        debug assert(old.ptr == future.ptr && old.length >= future.length,
                     "Process writing a future MultiComponent either changed the passed "
                     "future MultiComponent slice to point elsewhere, or enlarged it");

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
        mixin(q{process.process(%s);}.format(processArgs!"*entityRange.futureComponent"()));
        entityRange.setFutureComponentCount(1);
    }
}
