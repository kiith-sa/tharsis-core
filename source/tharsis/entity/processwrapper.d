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
    /// Runs the process on all matching entities from specified entity manager.
    void run(EntityManager!Policy entities) nothrow
private:
    /// Name of the process.
    string name_;

    {
        assert(false, "DMD (2065) bug workaround - should never happen");
    }

    /// Get name of the wrapped process.
    string name() @safe pure nothrow const @nogc { return name_; }
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
    /// A generated function that runs the process on all matching entities.
    ///
    /// The EntityManager parameter provides the entities to process; the
    /// Process parameter is the process whose process() method/s will be
    /// called.
    ///
    /// Can be changed into delegate if needed, but try to keep it a function.
    alias void function(EntityManager!Policy, Process) nothrow ProcessFunction;

    /// Construct a ProcessWrapper.
    ///
    /// Params: process    = The process to wrap.
    ///         runProcess = Function that, passed the an entity manager and the
    ///                      process, will run the process on all entities with
    ///                      components matching the process() method/s of the
    ///                      process.
    this(Process process, ProcessFunction runProcess) nothrow
    {
        process_    = process;
        runProcess_ = runProcess;
        name_       = Process.stringof;
    }

    override void run(EntityManager!Policy entities) nothrow
    {
        runProcess_(entities, process_);
    }
}
