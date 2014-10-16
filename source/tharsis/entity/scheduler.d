//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Scheduler that assigns Processes to threads and related utility code.
module tharsis.entity.scheduler;

import std.algorithm;
import std.exception: assumeWontThrow;
import std.range: iota;

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

    // Diagnostics for the scheduler, like scheduling algorithm, estimated frame etc.
    SchedulerDiagnostics diagnostics_;

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

    import tharsis.prof;
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
     * profiler    = Profiler to record scheduling overhead with.
     */
    void updateSchedule(Policy)(AbstractProcessWrapper!Policy[] processes,
                                ref const EntityManagerDiagnostics!Policy diagnostics,
                                Profiler profiler)
        @safe nothrow
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
        }
    }
}


import std.array: front, back, popFront, popBack, empty;
import std.typecons: Flag, Yes, No;

import tharsis.std.internal.scopebuffer;

/// Information about a process for scheduling purposes.
struct ProcessInfo
{
    import tharsis.entity.diagnostics;

    /// Thread the process is assigned to. uint.max if not assigned yet.
    uint assignedThread = uint.max;
    /// Diagnostics of the process (such as run time).
    ProcessDiagnostics diagnostics;

    /// Allow to access diagnostics members directly.
    alias diagnostics this;
}


/** Base class for scheduling algorithm.
 *
 * The actual algorithms are used by calling beginScheduling(), passing parameters by
 * addProcess()/increaseThreadUsage() and running the algorithm itself in endScheduling().
 *
 * The only reason for a persistent class that exists between multiple
 * beginScheduling()/endScheduling() pairs is to reuse resources (allocated memory);
 * it would also be possible to separate the scheduling algorithms into short-lived RAII
 * structs that access these resources through an external struct.
 */
class SchedulingAlgorithm
{
private:
    // Are we between beginScheduling()/endScheduling() right now?
    bool scheduling_ = false;

protected:
    // Number of threads we're scheduling for.
    const size_t threadCount_;
    // Estimated usage (run time) of inidivual threads (depends on which processes run where).
    ulong[] threadUsage_;


    // Default storage for procInfo_.
    ProcessInfo[64] procInfoScratch_;
    // Information about processes to schedule (added by addProcess(), cleared by
    // beginScheduling()).
    //
    // Order of processes here may not match their IDs/indices, see procIDToProcInfo_.
    ScopeBuffer!ProcessInfo procInfo_;

    // Default storage for procIDToProcInfo_.
    uint[64] procIDToProcInfoScratch_;
    // Translates process IDs (indices) to their corresponding procInfo_ elements.
    //
    // procIDToProcInfo_[processID] is the procInfo_ index of process with that ID.
    // Note that this relies on process IDs being 'small', as they are now since they
    // are indices of those processes as stored by EntityManager.
    ScopeBuffer!uint procIDToProcInfo_;


public:
    /** Construct a scheduling algorithm for specified number of threads.
     *
     * Params:
     *
     * threadCount = Number of threads to schedule processes into.
     */
    this(size_t threadCount) @trusted pure nothrow
    {
        assert(threadCount > 0, "Can't schedule with 0 threads");

        threadCount_ = threadCount;
        threadUsage_ = new ulong[threadCount];

        procInfo_ = scopeBuffer(procInfoScratch_);
        procIDToProcInfo_ = scopeBuffer(procIDToProcInfoScratch_);
    }

    /// Must be called to free resources used by the algorithm.
    ~this()
    {
        procInfo_.free();
        procIDToProcInfo_.free();
    }

    /// Get the name of the algorithm.
    string name() @safe pure nothrow const @nogc { assert(false, "Must be overridden"); }

    /** Get the estimated usage (run time) of thread with specified index.
     *
     * Can only be called after endScheduling().
     */
    final ulong estimatedThreadUsage(size_t thread) @safe pure nothrow const @nogc
    {
        assert(!scheduling_, "Can only get scheduled thread usage when done scheduling");
        return threadUsage_[thread];
    }

    /** Get the thread the process with specified ID (index) should run in.
     *
     * Can only be called after endScheduling().
     */
    final uint assignedThread(size_t process) @safe pure nothrow const @nogc
    out(result)
    {
        assert(result != uint.max, "process was not assigned a thread (probably bug)");
    }
    body
    {
        assert(!scheduling_,
               "Can only get the thread a process is scheduled to when done scheduling");
        assert(knowProcess(process),
               "Called assignedThread for a process not known to the scheduling algorithm");
        return procInfo(process).assignedThread;
    }

    /** Increase thread usage (estimated run time) for specified thread.
     *
     * Can only be called between beginScheduling() and endScheduling(). Used to tell the
     * scheduling algorithm about thread usage by processes that are not scheduled by the
     * algorithm (e.g. processes fixed to specific threads).
     */
    final void increaseThreadUsage(size_t thread, ulong usage) @safe pure nothrow @nogc
    {
        assert(scheduling_, "Can only increase baseline thread usage while scheduling");
        threadUsage_[thread] += usage;
    }

    /** Add a process for the algorithm to schedule.
     *
     * Most be used to add all processes to schedule after each call to beginScheduling().
     *
     * Params:
     *
     * process     = ID (index) of the process.
     * diagnostics = Diagnostics of the process, including its run time used for scheduling.
     */
    final void addProcess(size_t process, ref const ProcessDiagnostics diagnostics)
        @trusted nothrow
    {
        assert(scheduling_, "Can only get pass process diagnostics while scheduling");
        if(knowProcess(process))
        {
            procInfo(process).diagnostics = diagnostics;
            return;
        }

        // Don't know this process yet, add it.

        // Lengthten the proc ID -> proc info lookup table if needed.
        while(procIDToProcInfo_.length <= process) { procIDToProcInfo_.put(uint.max); }
        procIDToProcInfo_[process] = cast(uint)procInfo_.length;
        procInfo_.put(ProcessInfo.init);
        assert(knowProcess(process),
               "Setting procIDToProcInfo_ must result in knowing the process");
        procInfo(process).diagnostics = diagnostics;
    }

    /** Begin passing arguments to the scheduling algorithm.
     *
     * Forgets all processes added since the last beginScheduling() call; information
     * about processes must be readded through addProcess() before doing the actual 
     * scheduling in endScheduling().
     */
    final void beginScheduling() @trusted pure nothrow @nogc
    {
        assert(!scheduling_, "Called beginScheduling twice");
        procInfo_.length         = 0;
        procIDToProcInfo_.length = 0;
        scheduling_    = true;
        threadUsage_[] = 0;
    }

    /** End scheduling, running the actual scheduling algorithm.
     *
     * Schedules all processes passed through addProcess() calls. After calling this, 
     * threads assigned to processes and estimated thread runtime can be read through
     * assignedThread() and estimatedThreadUsage().
     *
     * beginScheduling() must be called first.
     */
    final Flag!"approximate" endScheduling() @safe nothrow
    {
        assert(scheduling_, "Called endScheduling when not scheduling");
        scope(exit) { scheduling_ = false; }
        return doScheduling();
    }

protected:
    /// Internal implementation of endScheduling(). Runs the scheduling algorithm.
    Flag!"approximate" doScheduling() @safe nothrow
    {
        // Implemented because of a DMD bug as of 2.066
        assert(false, "BUG: Default doScheduling() implementation should never be called");
    }

    /// Do we know a process with specified ID (index)?
    bool knowProcess(size_t process) @trusted pure nothrow const @nogc
    {
        return procIDToProcInfo_.length > process && procIDToProcInfo_[process] != size_t.max;
    }

    /// Access process info of process with specified ID (index).
    ref inout(ProcessInfo) procInfo(size_t process) @trusted pure inout nothrow @nogc
    {
        assert(knowProcess(process), "Can't get procInfo for process we don't know");
        return procInfo_[procIDToProcInfo_[process]];
    }
}


/** Extremely basic/dumb scheduling algorithm.
 *
 * Assigns roughly equal numbers of processes to each thread, without considering run
 * time estimates.
 */
class DumbScheduling: SchedulingAlgorithm
{
    /// Construct DumbScheduling algorithm for specified number of threads.
    this(size_t threadCount) @safe pure nothrow
    {
        super(threadCount);
    }

    override string name() @safe pure nothrow const @nogc { return "Dumb"; }

    override Flag!"approximate" doScheduling() @trusted nothrow
    {
        size_t thread = 0;
        foreach(i, ref process; procInfo_[])
        {
            process.assignedThread = cast(uint)thread;
            thread = (thread + 1) % threadCount_;
        }
        return Yes.approximate;
    }
}

/** Randomized backtracking that decides randomly on which branch of the call tree to
 * take, but covers all branches that it didn't backtrack from.
 *
 * Takes multiple 'attempts' to backtrack, each with limited 'time' (the number of
 * recursive backtrack calls to give up after). Each next attempt remembers the best
 * result of the previous attempt to cull the backtrack tree early, and uses different
 * random order to traverse the branches (i.e. tries assigning threads to processes in a
 * different order).
 *
 * If attempts are exhausted, the best result so far is used.
 */
class RandomBacktrackScheduling: SchedulingAlgorithm
{
private:
    // Default storage for procThreads_.
    uint[64] procThreadsScratch_;
    /* Working buffer for process/thread assignment.
     *
     * procThreads[i] is the index of thread in which the process described in
     * SchedulingAlgorithm.procInfo_[i] is assigned to run.
     */
    ScopeBuffer!uint procThreads_;

    // Default storage for coverBuffers_.
    bool[][64] coverBuffersScratch_;
    /* Buffers used by randomCover() calls to keep track of which branches of the
     * backtrack tree were taken.
     *
     * Need one buffer per recursion level, i.e. one buffer per process.
     */
    ScopeBuffer!(bool[]) coverBuffers_;

    // Stores estimated run times of threads as process/thread assignments are evaluated.
    ulong[] tempThreadUsage_;
    // Estimated run times of threads for the best process/thread assignment so far.
    ulong[] bestThreadUsage_;

    // A threadCount_ long array of [0, 1, 2 ...] - for randomCover().
    uint[] threadIndices_;

    // Maximum number of backtrack calls to do before giving up an attempt.
    ulong maxBacktrackTime_;

    // Maximum attempts to try.
    uint maxBacktrackAttempts_;

public:
    /** Construct RandomBacktrackScheduling algorithm for specified number of threads.
     *
     * Params:
     *
     * threadCount          = Number of threads to schedule processes to.
     * maxBacktrackTime     = Maximum number of backtrack calls to do before giving up an
     *                        attempt.
     * maxBacktrackAttempts = Maximum attempts to try. Must be a positive number.
     */
    this(size_t threadCount, ulong maxBacktrackTime, uint maxBacktrackAttempts) @trusted nothrow
    {
        assert(maxBacktrackAttempts > 0, "Can't schedule with 0 attempts");

        super(threadCount);
        maxBacktrackTime_     = maxBacktrackTime;
        maxBacktrackAttempts_ = maxBacktrackAttempts;

        // Init/alloc needed buffers.
        procThreads_  = scopeBuffer(procThreadsScratch_);
        coverBuffers_ = scopeBuffer(coverBuffersScratch_);

        tempThreadUsage_ = new ulong[threadCount];
        bestThreadUsage_ = new ulong[threadCount];
        threadIndices_   = new uint[threadCount_];
        iota(cast(uint)threadCount_).copy(threadIndices_);
    }

    /// Free resources.
    ~this()
    {
        procThreads_.free();
        coverBuffers_.free();
    }

    override string name() @safe pure nothrow const @nogc { return "RandomBacktrack"; }

    override Flag!"approximate" doScheduling() @trusted nothrow
    {
        auto procCount = procInfo_.length;

        // If not enough space in out buffers, lengthten them.
        while(procThreads_.length < procCount) { procThreads_.put(uint.max); }
        procThreads_.length = procCount;
        procThreads_[][] = uint.max;
        while(coverBuffers_.length < procCount) { coverBuffers_.put(new bool[threadCount_]); }
        coverBuffers_.length = procCount;

        // Best cost of a schedule we came up so far.
        ulong minCost = ulong.max;
        // import std.stdio;
        // scope(exit) { writeln("smart: ", minCost, " ", threadUsage_).assumeWontThrow; }

        // Whether we give up or not, update thread usage.
        scope(exit) { threadUsage_[] = bestThreadUsage_[]; }

        foreach(attempt; 0 .. maxBacktrackAttempts_)
        {
            // If we didn't give up, we found the best solution.
            if(backtrackAttempt(minCost).assumeWontThrow == No.givenUp)
            {
                return No.approximate;
            }
        }

        // If we've reached here, we've given up on all attempts and only have an
        // approximation.
        return Yes.approximate;
    }

private:
    /* A single attempt to find the best assignment of processes to threads by backtracking.
     *
     * Params:
     *
     * minCost = The best cost (estimated run time of worst thread) we got in previous
     *           attempts so far.
     *
     * Returns: Yes.givenUp if we ran out of time before exploring all possible best
     *          process/thread assignments, No.givenUp otherwise. If No.givenUp is
     *          returned, the result is optimal (we can't get any better).
     *
     * Never throws (enforce this with assumeWontThrow()).
     */
    Flag!"givenUp" backtrackAttempt(ref ulong minCost) @system
    {
        import tharsis.std.random: randomCover;
        bool[][] coverStack = coverBuffers_[];

        // Time spent in backtrack (number of backtrack() calls). We give up if we
        // run out of time.
        ulong time = 0;
        auto givenUp = No.givenUp;

        tempThreadUsage_[] = threadUsage_[];
        /* Params:
         *
         * procIdx   = Index of the process to assign to a thread in this backtrack call.
         * threadIdx = Thread to assign the process at procIdx to.
         */
        void backtrack(uint procIdx, uint threadIdx)
        {
            givenUp = time > maxBacktrackTime_ ? Yes.givenUp : No.givenUp;
            if(givenUp) { return; }
            ++time;

            procThreads_[procIdx] = threadIdx;

            // Add the duration of process at procIdx to thread at threadIdx, and subtract
            // it when we return.
            const duration = procInfo_[procIdx].duration;
            tempThreadUsage_[threadIdx] += duration;
            scope(exit) { tempThreadUsage_[threadIdx] -= duration; }

            const cost = reduce!max(tempThreadUsage_);
            // Backtrack when it's clear we won't get better than min cost.
            if(cost >= minCost) { return; }

            // Reached the deepest recursion level (assigned threads to all processes),
            // and have better cost than minCost (otherwise the above if() would return).
            if(procIdx == procInfo_.length - 1)
            {
                minCost = cost;
                foreach(i, thread; procThreads_) { procInfo_[i].assignedThread = thread; }
                bestThreadUsage_[] = tempThreadUsage_[];
                return;
            }

            // Randomly decide which thread to assign when (but try them all).
            foreach(uint nextThread; randomCover(threadIndices_, coverStack[procIdx + 1]))
            {
                backtrack(procIdx + 1, nextThread);
            }
        }

        // Randomly decide which thread to assign when (but try them all).
        foreach(uint thread; randomCover(threadIndices_, coverStack[0]))
        {
            backtrack(0, thread);
        }

        return givenUp;
    }
}


/** Plain, old school, extremely slow backtracking.
 *
 * Used only to test the optimality of results of other scheduling algorithms.
 */
class PlainBacktrackScheduling: SchedulingAlgorithm
{
    /// Construct PlainBacktrack algorithm for specified number of threads.
    this(size_t threadCount) @safe pure nothrow
    {
        super(threadCount);
    }

    override string name() @safe pure nothrow const @nogc { return "PlainBacktrack"; }

    override Flag!"approximate" doScheduling() @trusted nothrow
    {
        const procCount = procInfo_.length;

        // This is for testing, we don't care about GC overhead.
        uint[] procThreads      = new uint[procCount];
        ulong[] threadCosts     = new ulong[threadCount_];
        ulong[] bestThreadCosts = new ulong[threadCount_];

        // Evaluate a partial assignment of threads to processes (get running time of
        // worst thread)
        ulong evaluate(uint[] procThreads) nothrow
        {
            threadCosts[] = threadUsage_[];
            foreach(i, thread; procThreads)
            {
                procInfo_[i].assignedThread = thread;
                threadCosts[thread] += procInfo_[i].duration;
            }
            return reduce!max(threadCosts).assumeWontThrow;
        }

        ulong minCost = ulong.max;
        // import std.stdio;
        // scope(exit) { writeln("dumb: ", minCost, " ", threadUsage_).assumeWontThrow; }

        void backtrack(uint procIdx, uint threadIdx) nothrow
        {
            procThreads[procIdx] = threadIdx;

            const cost = evaluate(procThreads[0 .. procIdx + 1]);
            if(cost >= minCost) { return; }

            // We've assigned threads to all processes, and we have better cost than minCost.
            if(procIdx == procCount - 1)
            {
                minCost = cost;
                // Assign threads to processes.
                foreach(i, thread; procThreads) { procInfo_[i].assignedThread = thread; }
                bestThreadCosts[] = threadCosts[];
                return;
            }

            // Go deeper, assign a thread to the next process.
            foreach(uint next; 0 .. cast(uint)threadCount_) { backtrack(procIdx + 1, next); }
        }

        foreach(uint thread; 0 .. cast(uint)threadCount_) { backtrack(0, thread); }

        threadUsage_[] = bestThreadCosts[];

        return No.approximate;
    }
}

/** Longest processing time scheduling algorithm.
 *
 * Fast and gets decent results.
 */
class LPTScheduling: SchedulingAlgorithm
{
private:
    // Default storage for procIndex_.
    uint[64] processIndexScratch_;
    // Used in doScheduling() to store an index of procInfo_ sorted by process run duration.
    ScopeBuffer!uint procIndex_;

public:
    /// Construct LPTScheduling algorithm for specified number of threads.
    this(size_t threadCount) @trusted nothrow
    {
        super(threadCount);
        procIndex_ = scopeBuffer(processIndexScratch_);
    }

    /// Free resources used by the algorithm.
    ~this() { procIndex_.free(); }

    override string name() @safe pure nothrow const @nogc { return "LPT"; }

    override Flag!"approximate" doScheduling() @trusted nothrow
    {
        // Lengthten procIndex_ if needed.
        while(procIndex_.length < procInfo_.length) { procIndex_.put(0); }
        procIndex_.length = procInfo_.length;

        // Initialize procIndex_ as an array of indices to procInfo_ contents sorted
        // by process run duration.
        procInfo_[].makeIndex!((l, r) => l.duration < r.duration)(procIndex_[])
                   .assumeWontThrow;

        auto index = procIndex_[];
        // Check that we sorted it right.
        assert(procInfo_[index.back].duration >= procInfo_[index.front].duration,
               "Index not sorted from shorter to greater duration");

        // Assign processes to thread, from slowest to fastest, always to the thread with
        // least estimated time so far.
        while(!index.empty)
        {
            const longest = index.back;
            const duration = procInfo_[longest].duration;
            // minPos gets the range starting at position of the least used thread
            const threadIndex = threadUsage_.length - threadUsage_.minPos.length;
            threadUsage_[threadIndex] += duration;
            procInfo_[longest].assignedThread = cast(uint)threadIndex;

            index.popBack();
        }

        return No.approximate;
    }
}
