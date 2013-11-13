//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Stores data to create an entity from.
module tharsis.entity.entityprototype;


import std.algorithm;
import std.range;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.resourcemanager;


/// Stores data to create an entity from.
/// 
/// An EntityPrototoype stores components that can be copied to create an 
/// entity. Components can be loaded from a file once, and then used many times 
/// to create entities without loading again.
///
/// An EntityPrototype is usually used through PrototypeManager. The code 
/// that creates an EntityPrototype must provide it with memory as well as the 
/// components it should store
/// 
/// An EntityPrototype can't contain builtin components at the moment.
/// This restriction may be relaxed in future if needed.
struct EntityPrototype 
{
private:
    /// Storage provided to the EntityPrototype by its owner.
    ubyte[] storage_;

    /// Part of storage_ used to store type IDs.
    /// 
    /// Before lockAndTrimMemory() is called, this is at the end of storage_
    /// and in reverse order. When the memory is trimmed, this is moved right 
    /// after components_ and reversed into the same order as the order of 
    /// components stored in components_.
    ushort[] componentTypeIDs_;

    /// Part of storage_ used to store components. Starts at the beginning of
    /// storage_.
    ubyte[] components_;

    /// Set to true by lockAndTrimMemory(), after which no more components can 
    /// be added.
    bool locked_ = false;
     
public:
    /// Provide memory for the prototype to use. 
    /// 
    /// Must be called before adding any components.
    /// Can't be called more than once.'
    /// 
    /// Params: memory = Memory for the prototype to use. Must be enough for all 
    ///                  components that will be added to the prototype.
    void useMemory(ubyte[] memory) @safe pure nothrow
    {
        assert(!locked_, "Providing memory to a locked EntityPrototype");
        assert(storage_ == null, 
               "Trying to provide memory to an EntityPrototype that already "
               "has memory");
        assert(memory.length % 16 == 0, 
               "EntityPrototype memory must be divisible by 16");
        storage_ = memory;
        components_  = memory[0 .. 0];
        componentTypeIDs_ = cast(ushort[])memory[$ .. $];
    }

    /// Get the stored components as raw bytes.
    @property inout(ubyte)[] rawComponentBytes() @safe inout pure nothrow 
    {
        assert(locked_, "Trying to access raw components stored in an unlocked "
                        "EntityPrototype");
        return components_;
    }

    /// Allocate space for a component in the prototype. 
    /// 
    /// Can only be called between calls to useMemory() and lockAndTrimMemory().
    /// 
    /// Params: info = Type information about the component. Except for 
    ///                MultiComponents, multiple components of the same type 
    ///                can not be added.
    /// 
    /// Returns: A slice to write the component to. The component $(B must) be
    ///          written to this slice or the prototype must be thrown away.
    ubyte[] allocateComponent 
        (ComponentTypeInfo)(ref const(ComponentTypeInfo) info) @trusted nothrow
    {
        assert(!locked_, "Adding a component to a locked EntityPrototype");
        assert(info.id >= maxBuiltinComponentTypes, 
               "Trying to add a builtin component type to an EntityPrototype");
        assert(info.isMulti || !componentTypeIDs_.canFind(info.id), 
               "EntityPrototype with 2 non-multi components of the same type");

        assert(components_.length + info.size + 
               componentTypeIDs_.length * ushort.sizeof <= storage_.length,
               "Ran out of memory provided to an EntityPrototype");

        components_ = storage_[0 .. components_.length + info.size];

        // Position to write the component type ID at.
        const componentIDIndex = (cast(ushort[])storage_).length - 
                                 componentTypeIDs_.length - 1;
        componentTypeIDs_ = (cast(ushort[])storage_)[componentIDIndex .. $];
        componentTypeIDs_[0] = info.id;
        return components_[$ - info.size .. $];
    }


    /// Lock the prototype disallowing any future changes.
    ///
    /// Returns: the part of the memory passed by useMemory that is used by the 
    ///          prototype. The rest is unused and can be used by the caller for 
    ///          something else.
    const(ubyte)[] lockAndTrimMemory() @trusted pure nothrow
    {
        const usedBytes = components_.length;

        // Move componentTypeIDs_ to right after the used memory.
        const oldComponentIDs = componentTypeIDs_;
        const idBytes = oldComponentIDs.length * ushort.sizeof;
        componentTypeIDs_ = 
            cast(ushort[])storage_[usedBytes .. usedBytes + idBytes];
        foreach(i, id; oldComponentIDs) { componentTypeIDs_[$ - i - 1] = id; }

        const totalBytes = components_.length + idBytes;
        assert(storage_.length % 16 == 0, 
               "ComponentPrototype storage length not divisible by 16");
        
        // Align the used memory to 16.
        const alignedBytes = ((totalBytes + 15) / 16) * 16;

        storage_ = storage_[0 .. alignedBytes];

        locked_ = true;
        return storage_;
    }

    /// Get the component type IDs of stored components.
    ///
    /// Can only be called on locked prototypes.
    const(ushort[]) componentTypeIDs() @safe pure nothrow const
    {
        assert(locked_, 
               "Trying to get component type IDs of an unlocked entity "
               "prototype");
        return componentTypeIDs_;
    }
}


/// A resource wrapping an EntityPrototype. Managed by PrototypeManager.
struct EntityPrototypeResource 
{
    /// Resource handle.
    struct Handle 
    {
    package:
        /// A simple unique ID.
        uint resourceID_ = uint.max;
    }

    /// Resource descriptor.
    struct Descriptor 
    {
        /// The file name to load the prototype from.
        string fileName;
    }

    /// No default construction.
    @disable this();

    /// Construct a New (not loaded) EntityPrototypeResource with specified 
    /// descriptor.
    this(const ref Descriptor descriptor) @safe pure nothrow
    {
        this.descriptor = descriptor;
    }

    // Data can be public as we use this through immutable.

    /// The stored prototype, is state is ResourceState.New.
    EntityPrototype prototype;

    /// Descriptor of the prototype (i.e. its file name).
    Descriptor descriptor;

    /// Current state of the resource,
    ResourceState state = ResourceState.New; 
}
