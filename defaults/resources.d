//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Resource types included with Tharsis by default.
module tharsis.defaults.resources;

import std.algorithm;
import std.typecons;

import tharsis.defaults.descriptors;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitymanager;
import tharsis.entity.entityprototype;
import tharsis.entity.prototypemanager;
import tharsis.entity.resourcemanager;


/// A resource wrapping an EntityPrototype the source of which is embedded 
/// directly in a Source, not in a separate file.
///
/// Used e.g. for overriding components in a SpawnerComponent.
struct InlineEntityPrototypeResource
{ 
    /// The descriptor is a Source representing components of the prototype.
    alias SourceWrapperDescriptor!InlineEntityPrototypeResource Descriptor;

    /// No default construction.
    @disable this();

    /// Construct a new (not loaded) InlineEntityPrototypeResource with specified 
    /// descriptor.
    this(ref Descriptor descriptor) @safe pure nothrow
    {
        this.descriptor = descriptor;
    }

    /// Assignment - shallow copy of the members.
    void opAssign(ref InlineEntityPrototypeResource rhs) @safe pure nothrow
    {
        prototype  = rhs.prototype;
        descriptor = rhs.descriptor;
        state      = rhs.state;
    }

    // Data can be public as we use this through immutable.

    /// The entity prototype itself.
    EntityPrototype prototype;

    /// Descriptor - the Source representing components of the prototype.
    Descriptor descriptor;

    /// Current state of the resource,
    ResourceState state = ResourceState.New;  
}
