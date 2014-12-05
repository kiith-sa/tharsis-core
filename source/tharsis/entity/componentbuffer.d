//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Per-component type buffers.
module tharsis.entity.componentbuffer;


import std.algorithm;
import std.conv;
import std.exception: assumeWontThrow;
import std.stdio;

import tharsis.entity.componenttypeinfo;
import tharsis.util.mallocarray;


/** A buffer storing all (either past or future) components of one component type.
 *
 * The components are stored as plain bytes. Components are written by accessing unused
 * memory with unusedSpace(), writing the components, and "comitting" them with
 * commitComponents(). If there's not enough space for new components, the buffer must be
 * reallocated with reserveComponentSpace().
 */
struct ComponentBuffer(Policy)
{
private:
    // Size (in bytes) of a single component in this buffer.
    union
    {
        // Code that writes should use componentSize_, the rest should use componentSize.
        size_t componentSize_ = size_t.max;
        const size_t componentSize;
    }

    // The size of storage_ in components.
    size_t allocatedComponents_ = 0;

    // The number of components committed (written) so far.
    size_t committedComponents_;

    // Size of committed components in bytes (optimization).
    size_t committedBytes_;

    // The buffer itself. Stores components without any padding.
    MallocArray!ubyte storage_;

    // Is this ComponentBuffer enabled?
    //
    // (I.e. is there a component type that uses this ComponentBuffer?)
    bool enabled_ = false;

    // ID of the type of stored components.
    ushort componentTypeID_;

    // Name of the component type.
    string componentTypeName_;

    // Disable copying.
    @disable void opAssign(ref ComponentBuffer);
    @disable this(this);

public:
    /// Destroy this ComponentBuffer.
    ~this()
    {
        if(enabled_) { reset(); }
        storage_.destroy();
    }

    /** Enable the ComponentBuffer, meaning some component type uses it.
     *
     * Params: typeInfo = Info about the type of components to store.
     */
    void enable(ref const(ComponentTypeInfo) typeInfo) @safe pure nothrow @nogc
    {
        assert(!enabled_, "Trying to enable a component buffer that's already enabled. "
                          "Maybe two components with the same ComponentTypeID?");
        componentTypeID_   = typeInfo.id;
        componentTypeName_ = typeInfo.name;
        componentSize_     = typeInfo.size;
        enabled_           = true;
    }

    /// Get the memory that's not used yet.
    ///
    /// Components can be written to this memory, and then committed using
    /// commitComponents().
    ubyte[] uncommittedComponentSpace() @safe pure nothrow @nogc
    {
        assert(enabled_, "Can't get data of a buffer that is not enabled");
        return storage_[committedBytes_ .. $];
    }

    /// Get the memory used for the _committed_ components, i.e. those that
    /// have been written and exist as a part of one or another entity.
    const(ubyte)[] committedComponentSpace() const pure nothrow @safe @nogc
    {
        assert(enabled_, "Can't get data of a buffer that is not enabled");
        return storage_[0 .. committedBytes_];
    }

    /// Ditto.
    immutable(ubyte)[] committedComponentSpace() immutable pure nothrow @safe @nogc
    {
        assert(enabled_, "Can't get data of a buffer that is not enabled");
        return storage_[0 .. committedBytes_];
    }

    /** Commit components written to space returned by uncommittedSpace.
     *
     * After this is called, the components officially exist as a part of some entity.
     *
     * Params:  count = Number of components to commit.
     */
    void commitComponents(const size_t count) @safe pure nothrow @nogc
    {
        assert(enabled_, "Can't commit components to a buffer that's not enabled");
        assert(committedComponents_ + count <= allocatedComponents_,
               "Trying to commit more components than can fit in allocated space");

        committedComponents_ += count;
        committedBytes_      = committedComponents_ * componentSize;
    }

    /** Same as uncommittedComponentSpace, but reallocates if there's less than specified
     * space.
     *
     * Params:  minLength = Min number of components we need space for. If greater than
     *                      available uncommitted space, the buffer will be reallocated,
     *                      invalidating slices returned by previous method calls and
     *                      printing a warning to stdout so the user knows they need to 
     *                      preallocate more memory; reallocations should be uncommon.
     *
     * Returns: Uncommitted space, possibly after a reallocation.
     */
    ubyte[] forceUncommittedComponentSpace(const size_t minLength)
        @trusted nothrow
    {
        assert(enabled_, "Can't commit components to a buffer that's not enabled");
        if(allocatedComponents_ - committedComponents_ >= minLength)
        {
            return storage_[committedBytes_ .. $];
        }

        writefln("WARNING: Buffer reallocation for component type %s: consider "
                 "preallocating more space by setting compile-time tweakables "
                 "in EntityPolicy or the component type, or increasing "
                 "EntityManager.allocMult.\n"
                 "EntityPolicy allocation tweakables:\n"
                 "  uint minComponentPrealloc\n"
                 "  float reallocMult\n"
                 "  float minComponentPerEntityPrealloc\n"
                 "Component type tweakables:\n"
                 "  uint minPrealloc\n"
                 "  float minPreallocPerEntity\n"
                 "See Component and EntityPolicy documentation for updated information.",
                 componentTypeName_).assumeWontThrow();
        const components = max(minLength, to!size_t(allocatedComponents_ * Policy.reallocMult)
                           .assumeWontThrow);
        reserveComponentSpace(components);
        return uncommittedComponentSpace;
    }

    /// Add a component to the buffer by copying a raw component.
    ///
    /// Usually, components should be added by getting uncommittedSpace(),
    /// directly writing to it and then committing the components. For cases
    /// where the component is added from an existing buffer (entity
    /// prototypes), a copy is unavoidable; this method is used in this case.
    ///
    /// Params: component = The component to add as a raw, untyped component.
    void addComponent(ref const(RawComponent) component)
    {
        assert(component.typeID == componentTypeID_ &&
               component.componentData.length == componentSize,
               "Component to add has unexpected component type and/or size");

        // Ensure the (rare) case of running out of space is handled.
        ubyte[] uncommitted = forceUncommittedComponentSpace(1);
        uncommitted[0 .. componentSize] = component.componentData[];
        commitComponents(1);
    }

    /// Reserve space for more components.
    ///
    /// Must be called if uncomittedComponentSpace() is not long enough to store
    /// components we need to add. Invalidates any slices returned by previous
    /// method calls.
    ///
    /// Params: componentCount = Number of components to allocate space for.
    void reserveComponentSpace(const size_t componentCount) @trusted nothrow
    {
        assert(enabled_, "Calling reserveComponentSpace on a non-enabled buffer");
        if(allocatedComponents_ >= componentCount) { return; }
        const oldBytes = storage_.length;
        const bytes    = componentSize * componentCount;
        storage_.reserve(bytes);
        storage_.growUninitialized(bytes);
        storage_[oldBytes .. $] = 0;
        allocatedComponents_ = componentCount;
    }

    /// Get the allocated space in components.
    size_t allocatedSize() @safe const pure nothrow @nogc
    {
        // The length, not capacity, counts as allocated space for this API.
        return allocatedComponents_;
    }

    /// Get the size of a single component in bytes.
    size_t componentBytes() @safe pure nothrow const @nogc { return componentSize; }

    /// Get the number of committed (fully written) components.
    size_t committedComponents() @safe pure nothrow const @nogc { return committedComponents_; }

    /** Clear a ComponentBuffer before use as a future component buffer to catch any bugs
     *  with reading no longer used data.
     *
     * This exists only to catch bugs, and can be removed if the overhead is too high.
     */
    void reset() @safe pure nothrow @nogc
    {
        assert(enabled_, "Can't reset a non-enabled buffer");
        storage_[]           = 0;
        committedComponents_ = 0;
        committedBytes_      = 0;
    }
}
