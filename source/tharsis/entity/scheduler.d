//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Scheduler that assigns Processes to threads and related utility code.
module tharsis.entity.scheduler;


import tharsis.entity.diagnostics;
import tharsis.entity.processwrapper;
import tharsis.util.mallocarray;


// core.cpuid only works for getting threads per CPU on x86 (for now).
version(X86)    { version = cpuidSupported; }
version(X86_64) { version = cpuidSupported; }

/** Determine the best thread count for the current CPU and return it.
 *
 * Tharsis will use this number of threads (including the main thread), unless overridden
 * with EntityManager constructor.
 */
size_t autodetectThreadCount() @safe nothrow @nogc
{
    version(cpuidSupported)
    {
        import core.cpuid;
        return threadsPerCPU();
    }
    else { return 4; }
}

package:

/// The default number of threads if we have no idea (e.g. on ARM - 4 is a good guess).
enum defaultThreadCount = 4;



/// Determines which Processes should run in which threads, as well as the thread count.
class Scheduler
{
private:
    import core.thread;

    // Number of threads used (including the main thread).
    size_t threadCount_;

    // TODO: Use manual allocation (ideally std.container.Array+std.allocator *after
    // released*) 2014-09-15
    /* Maps processes to threads.
     *
     * processToThread_[i] is the index of thread process i is scheduled to run in)
     */
    uint[] processToThread_;

    /// Number of processes in each thread.
    MallocArray!uint processesPerThread_;

public:
    /** Construct a Scheduler.
     *
     * Params:
     *
     * overrideThreadCount = If non-zero, thread count will be set to exactly this value.
     *                       Otherwise, it will be autodetected (e.g. 4 on a quad-core,
     *                       8 on an octal-core or on a quad-core with hyper threading)
     */
    this(size_t overrideThreadCount) @system nothrow
    {
        threadCount_ = overrideThreadCount == 0 ? autodetectThreadCount()
                                                : overrideThreadCount;

        processesPerThread_.reserve(threadCount_);
        processesPerThread_.growUninitialized(threadCount_);
        processesPerThread_[] = 0;
    }

    /// Get the number of threads to use.
    size_t threadCount() @safe pure nothrow const @nogc { return threadCount_; }

    /// Get the index of the thread a process with index processIndex should run in.
    uint processToThread(size_t processIndex) @safe pure nothrow const @nogc
    {
        return processToThread_[processIndex];
    }

    /** Reschedule processes between threads.
     *
     * Provides information for Scheduler to decide how to assign Processes to threads.
     *
     * Params:
     *
     * processes   = Processes to schedule, wrapped in process wrappers. These are the 
     *               processes used *this update* (it's possible that registered processes
     *               could change between updates in future).
     * diagnostics = EntityManager diagnostics from the previous game update. Includes
     *               time durations spent executing individual processes during the
     *               previous update.
     */
    void updateSchedule(Policy)(AbstractProcessWrapper!Policy[] processes,
                                ref const EntityManagerDiagnostics!Policy diagnostics)
        @safe pure nothrow
    {
        if(processToThread_.length != processes.length)
        {
            processToThread_.length = processes.length;
        }


        processesPerThread_[] = 0;
        // First look for processes bound to specific threads.
        foreach(uint i, proc; processes) if(proc.boundToThread != uint.max)
        {
            const thread = proc.boundToThread % threadCount_;
            processToThread_[i] = thread;
            processesPerThread_[thread] = processesPerThread_[thread] + 1;
        }

        const targetProcPerThread = (processes.length + threadCount - 1) / threadCount;
        uint thread = 0;

        // Now assign threads to processes that are not bound to any specific thread.
        foreach(uint i, proc; processes) if(proc.boundToThread == uint.max)
        {
            assert(thread < threadCount_, "Thread out of range");
            if(processesPerThread_[thread] >= targetProcPerThread)
            {
                ++thread;
            }
            processToThread_[i] = thread;
            processesPerThread_[thread] = processesPerThread_[thread] + 1;
        }
    }
}
