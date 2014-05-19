//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Stores data to create an entity from.
module tharsis.entity.entityprototype;


import std.algorithm;
import std.range;
import std.traits;
import std.typecons;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.descriptors;
import tharsis.entity.resourcemanager;
import tharsis.util.alloc;
import tharsis.util.array;
import tharsis.util.math;
import tharsis.util.stackbuffer;


// TODO eventually we will want a way to construct an EntityPrototype by adding
//      components as structs without messing around with untyped data. This could be
//      done using a wrapper (PrototypeBuilder?) that would include component type info.

/// Stores data to create an entity from.
///
/// An EntityPrototoype stores components that can be copied to create an entity.
/// Components can be loaded from a file once, and then used many times to create
/// entities without loading again.
///
/// An EntityPrototype is usually used through PrototypeManager. Code that creates an
/// EntityPrototype must provide it with memory as well as the components it should
/// store.
///
/// An EntityPrototype can't contain builtin components at the moment. This restriction
/// may be relaxed in future if needed.
struct EntityPrototype
{
private:
    /// Storage provided to the EntityPrototype by its owner.
    ///
    /// Both componentTypeIDs_ and components_ point to this storage. Passed by
    /// useMemory(). Never resized; running out of this space triggers an assert error.
    ///
    /// After a call to lockAndTrimMemory, componentTypeIDs_ and components_ are packed
    /// and the length of storage_ is decreased to only the used space.
    ubyte[] storage_;

    /// Part of storage_ used to store type IDs.
    ///
    /// Before lockAndTrimMemory() is called, this is at the end of storage_ and in
    /// reverse order. When the memory is trimmed, this is reordered to match the order
    /// of the (now sorted) components_ (not in reverse order), and moved to the end of
    /// storage_. It may start right after components_ or after an alignment gap.
    ///
    /// For MultiComponents, one ID is stored for each component even if they have the
    /// same type.
    ushort[] componentTypeIDs_;

    /// Part of storage_ used to store components. Starts at the beginning of storage_.
    /// After a call to loacAndTrimMemory, components are sorted by component type ID.
    ubyte[] components_;

    /// Set to true by lockAndTrimMemory(), after which no more components can be added.
    bool locked_ = false;

public:
    /// A range to iterate over components in an EntityPrototype.
    ///
    /// If the isConst parameter is true, the range can only read components. Otherwise
    /// the components can be modified.
    ///
    /// The components are iterated as RawComponents, i.e. raw byte data with type ID.
    /// Usually they will need to be cast to an actual component type to be useful.
    struct GenericComponentRange(Flag!"isConst" isConst)
    {
    private:
        /// Work with a const or non-const EntityPrototype depending on isConst.
        alias Prototype = Select!(isConst, const(EntityPrototype), EntityPrototype);

        /// The entity prototype we're iterating over.
        Prototype* prototype_;

        /// Type information about all component types.
        ///
        /// (This is a slice to ComponentTypeManager data).
        const(ComponentTypeInfo)[] componentTypeInfo_;

        /// Index of the current component in the prototype.
        ///
        /// Used with Prototype.componentTypeIDs_ to get type of the current component.
        size_t componentIndex_ = 0;

        /// Offset, in bytes, where the current component in Prototype.components_
        /// starts.
        size_t componentOffset_ = 0;

        /// Current element of the range (type ID + slice with component data).
        ///
        /// Storing front_ allows access through a const (inout) reference.
        RawComponent front_;

        /// No copying.
        @disable this(this);
        @disable this();

        /// Construct a component range.
        ///
        /// Params:  prototype         = Entity prototype to iterate over.
        ///          componentTypeInfo = Type info about all registered component types.
        this(ref Prototype prototype, const(ComponentTypeInfo)[] componentTypeInfo)
            pure nothrow
        {
            assert(prototype.locked_, "ComponentRange needs a locked EntityPrototype");
            prototype_         = &prototype;
            componentTypeInfo_ = componentTypeInfo;
            updateFront();
        }

    public:
        /// Get the current component.
        ///
        /// Must not be called if the range is empty.
        ref inout(RawComponent) front() @safe pure nothrow inout
        {
            assert(!empty, "Can't get front of an empty range");
            return front_;
        }

        /// Go to the next component.
        ///
        /// Must not be called if the range is empty.
        void popFront() @safe pure nothrow
        {
            assert(!empty, "Can't pop front of an empty range");
            const type = prototype_.componentTypeIDs_[componentIndex_];
            componentOffset_ += componentTypeInfo_[type].size;
            ++componentIndex_;
            updateFront();
        }

        /// Is the range empty (no more components) ?
        bool empty() @safe pure nothrow const
        {
            return componentIndex_ >= prototype_.componentTypeIDs_.length;
        }

    private:
        /// Update the front_ data member.
        void updateFront() @trusted pure nothrow
        {
            // front_ is invalid when the range is empty.
            if(empty) { return; }
            const type = prototype_.componentTypeIDs_[componentIndex_];
            const size = componentTypeInfo_[type].size;
            auto  data = prototype_.components_[componentOffset_ ..
                                                componentOffset_ + size];

            // The cast is OK if isConst == true; front() will only allow const access.
            front_ = RawComponent(type, cast(ubyte[])data);
        }
    }

    /// See_Also: GenericComponentRange
    alias ComponentRange      = GenericComponentRange!(No.isConst);
    /// See_Also: GenericComponentRange
    alias ConstComponentRange = GenericComponentRange!(Yes.isConst);

    /// Get a range to iterate over components in the prototype as RawComponents.
    ///
    /// Params:  componentTypeManager = Manager with type info of all component types.
    ComponentRange componentRange(AbstractComponentTypeManager componentTypeManager)
        pure nothrow
    {
        return ComponentRange(this, componentTypeManager.componentTypeInfo);
    }

    /// Get a range to iterate over components in the prototype as RawComponents.
    ///
    /// Params:  componentTypeInfo = Slice with type info of all component types.
    ComponentRange componentRange(const(ComponentTypeInfo)[] componentTypeInfo)
        pure nothrow
    {
        return ComponentRange(this, componentTypeInfo);
    }

    /// Ditto.
    ConstComponentRange constComponentRange
        (const(ComponentTypeInfo)[] componentTypeInfo) pure nothrow const
    {
        return ConstComponentRange(this, componentTypeInfo);
    }


    /// Provide memory for the prototype to use.
    ///
    /// Must be called before adding any components. Can only be called once.
    ///
    /// Size of passed memory must be enough for all components that will be added to
    /// this prototype, plus ushort.sizeof per component for component type IDs. Size of
    /// passed memory should be aligned upwards to a multiple of 16.
    ///
    /// Params: memory = Memory for the prototype to use. Must be at least
    ///                  maxPrototypeBytes() bytes long.
    void useMemory(ubyte[] memory) @safe pure nothrow
    {
        assert(!locked_, "Providing memory to a locked EntityPrototype");
        assert(storage_ == null,
               "Trying to provide memory to an EntityPrototype that already has memory");
        assert(memory.length % 16 == 0,
               "EntityPrototype memory must be divisible by 16");

        storage_          = memory;
        components_       = memory[0 .. 0];
        componentTypeIDs_ = cast(ushort[])memory[$ .. $];
    }

    /// Get the maximum number of bytes any entity prototype might need.
    ///
    /// Used to determine minimum size of memory to pass to EntityPrototype.useMemory().
    /// Most prototypes are likely to be very small; this is the size of memory needed
    /// to avoid *any* prototype running out of memory.
    ///
    /// Params: componentTypeManager = Component type manager with which all used
    ///                                component types are registered.
    static size_t maxPrototypeBytes(AbstractComponentTypeManager componentTypeManager)
        @safe pure nothrow
    {
        return componentTypeManager.maxEntityBytes + 32 +
               componentTypeManager.maxEntityComponents * ushort.sizeof;
    }

    /// Allocate space for a component in the prototype.
    ///
    /// Can only be called between calls to useMemory() and lockAndTrimMemory().
    ///
    /// Params: info = Type information about the component. Except for MultiComponents,
    ///                multiple components of the same type can not be added.
    ///
    /// Returns: A slice to write the component to. The component $(B must) be written
    ///          to this slice or the prototype must be thrown away.
    ubyte[] allocateComponent(ref const(ComponentTypeInfo) info) @trusted nothrow
    {
        assert(!locked_, "Adding a component to a locked EntityPrototype");
        assert(info.id >= maxBuiltinComponentTypes,
               "Trying to add a builtin component type to an EntityPrototype");
        assert(info.isMulti || !componentTypeIDs_.canFind(info.id),
               "EntityPrototype with 2 non-multi components of the same type");

        assert(components_.length + info.size + componentTypeIDs_.length * ushort.sizeof
               <= storage_.length,
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
    /// Trims used memory and aligns it to a multiple of 16.
    ///
    /// Params: componentTypes = Type information about all registered component types.
    ///
    /// Returns: Part of memory passed by useMemory that is used by the prototype. The
    ///          rest is unused and can be used by the caller for something else.
    const(ubyte)[] lockAndTrimMemory(const(ComponentTypeInfo)[] componentTypes)
        @trusted nothrow
    {
        const idBytes      = componentTypeIDs_.length * ushort.sizeof;
        const totalBytes   = components_.length + idBytes;
        // Used memory must be aligned to 16 bytes.
        const alignedBytes = totalBytes.alignUp(16);

        // Sort the components by type ID (simplifies component overriding when merging
        // entity prototypes).

        // Avoid heap allocation by using stack if the prototype is small.
        auto scratchBuffer = StackBuffer!(ubyte, 16 * 1024)(alignedBytes);

        // Number of components sorted so far.
        size_t sortedCount  = 0;
        // Offset in scratchBuffer where to place the next sorted component.
        size_t offsetNew    = 0;
        const compCount     = componentTypeIDs_.length;
        auto newCompTypeIDs = (cast(ushort[])scratchBuffer)[$ - compCount .. $];

        // Add components of every type (in order) to the sorted buffer.
        foreach(ref type; componentTypes) if(!type.isNull)
        {
            // Don't need to check other component types if all components have been
            // sorted already.
            if(sortedCount == compCount) { break; }

            assert(sortedCount <= compCount,
                   "Processed more components than present in the prototype");

            size_t offsetOld = 0;
            // Copy every component with matching type ID to the sorted buffer. Using
            // foreach_reverse since componentTypeIDs_ are in reverse order during
            // prototype construction.
            foreach_reverse(id; componentTypeIDs_)
            {
                const bytes = componentTypes[id].size;
                scope(exit) { offsetOld += bytes; }
                if(id != type.id) { continue; }

                const component = components_[offsetOld .. offsetOld + bytes];
                scratchBuffer[offsetNew .. offsetNew + bytes] = component[];
                offsetNew += bytes;
                newCompTypeIDs[sortedCount++] = id;
            }
        }

        assert(storage_.length % 16 == 0,
               "EntityPrototype storage length not aligned to 16");
        storage_ = storage_[0 .. alignedBytes];
        // Copy the sorted result to storage_.
        storage_[] = scratchBuffer[];
        componentTypeIDs_ = (cast(ushort[])storage_)[$ - compCount .. $];

        locked_ = true;
        return storage_;
    }
}


/// Merge two entity prototypes; components from over override components from base.
/// The returned prototype is not locked/trimmed.
///
/// The result is created by taking all components from base and adding components of
/// each type from over. If components of the same type are both in base and over,
/// component/s from over are used (overriding base).
///
/// Params: base           = The base for the merged prototype.
///         over           = Prototype with components added to/overriding components in
///                          base.
///         memory         = Memory to use for the new entity prototype. Must be at
///                          least EntityPrototype.maxPrototypeBytes() bytes long.
///         componentTypes = Type information about all registered component types.
///
/// Returns: The merged prototype. The prototype is not locked, allowing more components
///          to be added. To be used it must be locked by calling
///          EntityPrototype.lockAndTrimMemory().
EntityPrototype mergePrototypesOverride
    (ref const(EntityPrototype) base, ref const(EntityPrototype) over,
     ubyte[] memory, const(ComponentTypeInfo)[] componentTypes)
{
    EntityPrototype result;
    result.useMemory(memory);
    auto baseRange = base.constComponentRange(componentTypes);
    auto overRange = over.constComponentRange(componentTypes);

    while(!baseRange.empty || !overRange.empty)
    {
        // baseRange, overRange are sorted by component type. If baseRange.front.typeID
        // is less, there's no component with that ID in overRange so use component/s
        // from baseRange. Same for overRange.front.typeID and overRange. If the type
        // IDs are equal, both baseRange and overRange have this component and over
        // overrides base. If either is empty, we use the other one.

        const bool useBase = overRange.empty ? true  // only baseRange has items
                           : baseRange.empty ? false // only overRange has items
                           : baseRange.front.typeID < overRange.front.typeID;
        const typeID = useBase ? baseRange.front.typeID : overRange.front.typeID;

        // Copies to result components of the current type. Skips components of this
        // type in the ignored buffer. (Which is used, which ignored depends on whether
        // there's a component of this type in base and over - over overrides base.)
        static void copyComponents
            (ref EntityPrototype result,
             ref const ComponentTypeInfo type,
             ref EntityPrototype.ConstComponentRange usedRange,
             ref EntityPrototype.ConstComponentRange ignoredRange)
        {
            const typeID = usedRange.front.typeID;
            const size   = type.size;
            // Copy all components until we reach components of a different type or
            // until usedIDs is empty.
            while(!usedRange.empty && usedRange.front.typeID == typeID)
            {
                ubyte[] target = result.allocateComponent(type);
                target[]       = usedRange.front.componentData[0 .. size];
                usedRange.popFront();
            }
            // Ignore all overridden components from base.
            while(!ignoredRange.empty && ignoredRange.front.typeID == typeID)
            {
                ignoredRange.popFront();
            }
        }

        copyComponents(result, componentTypes[typeID],
                       useBase ? baseRange : overRange,
                       useBase ? overRange : baseRange);
    }

    return result;
}


/// A resource wrapping an EntityPrototype. Managed by PrototypeManager.
struct EntityPrototypeResource
{
    /// Described by the prototype filename, which is a string.
    alias StringDescriptor!EntityPrototypeResource Descriptor;

    /// No default construction.
    @disable this();

    /// Construct a new (not loaded) EntityPrototypeResource with specified descriptor.
    this(ref Descriptor descriptor) @safe pure nothrow
    {
        this.descriptor = descriptor;
    }

    // Data can be public as we use this through immutable.

    /// The stored prototype.
    EntityPrototype prototype;

    /// Descriptor of the prototype (i.e. its file name).
    Descriptor descriptor;

    /// Current state of the resource,
    ResourceState state = ResourceState.New;
}
