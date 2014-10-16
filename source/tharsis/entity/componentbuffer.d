//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Per-component type buffers.
module tharsis.entity.componentbuffer;


import std.algorithm;
import std.conv;
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
    /// Is this ComponentBuffer enabled?
    ///
    /// (I.e. is there a component type that uses this ComponentBuffer?)
    bool enabled_ = false;

    /// ID of the type of stored components.
    ushort componentTypeID_;

    /// Size (in bytes) of a single component in this buffer.
    size_t componentSize_ = size_t.max;

    /// The buffer itself. Stores components without any padding.
    MallocArray!ubyte storage_;

    /// The size of storage_ in components.
    size_t allocatedComponents_ = 0;

    /// The number of component committed (written) so far.
    size_t committedComponents_;

    /// Disable copying.
    @disable void opAssign(ref ComponentBuffer);
    @disable this(this);

public:
    /// Destroy this ComponentBuffer.
    ~this()
    {
        if(enabled_) { reset(); }
        storage_.destroy();
    }

    /// Enable the ComponentBuffer, meaning some component type uses it.
    ///
    /// Params: componentTypeID = ID of the type of stored components.
    ///         componentSize   = Size of a single stored component.
    void enable(const ushort componentTypeID, const size_t componentSize)
        @safe pure nothrow @nogc
    {
        assert(!enabled_, "Trying to enable a component buffer that's "
                          "already enabled. Maybe two components with "
                          "the same ComponentTypeID?");
        componentTypeID_ = componentTypeID;
        componentSize_   = componentSize;
        enabled_         = true;
    }

    /// Get the memory that's not used yet.
    ///
    /// Components can be written to this memory, and then committed using
    /// commitComponents().
    ubyte[] uncommittedComponentSpace() pure nothrow @safe @nogc
    {
        assert(enabled_, "Can't get data of a buffer that is not enabled");
        return storage_[componentSize_ * committedComponents_ .. $];
    }

    /// Get the memory used for the _committed_ components, i.e. those that
    /// have been written and exist as a part of one or another entity.
    const(ubyte)[] committedComponentSpace() const pure nothrow @safe @nogc
    {
        assert(enabled_, "Can't get data of a buffer that is not enabled");
        return storage_[0 .. componentSize_ * committedComponents_];
    }

    /// Ditto.
    immutable(ubyte)[] committedComponentSpace() immutable pure nothrow @safe @nogc
    {
        assert(enabled_, "Can't get data of a buffer that is not enabled");
        return storage_[0 .. componentSize_ * committedComponents_];
    }

    /// Commit components written to space returned by uncommittedSpace.
    ///
    /// After this is called, the components officially exist as a part of
    /// some entity.
    ///
    /// Params:  count = Number of components to commit.
    void commitComponents(const size_t count) @safe nothrow @nogc
    {
        assert(enabled_,
               "Can't commit components to a buffer that's not enabled");
        assert(committedComponents_ + count <= allocatedComponents_,
               "Trying to commit more components than can fit in allocated "
               "space");

        committedComponents_ += count;
    }

    /// Same as uncommittedComponentSpace, but reallocates if there's less than
    /// specified space.
    ///
    /// Params:  minLength = Minimum number of components we need space for.
    ///                      If this is greater than the available uncommitted
    ///                      space, the buffer will be reallocated, invalidating
    ///                      any slices returned by previous method calls,
    ///                      and printing a warning to stdout; reallocations
    ///                      in this method should be uncommon and the user
    ///                      should be notified about a need to preallocate more
    ///                      memory.
    ///
    /// Returns: Uncommitted space, possibly after a reallocation.
    ubyte[] forceUncommittedComponentSpace(const size_t minLength)
        @trusted nothrow
    {
        static ubyte[] implementation(ref ComponentBuffer self,
                                      const size_t minLength)
        {with(self){
            if(uncommittedSize >= minLength)
            {
                return uncommittedComponentSpace;
            }

            writefln("WARNING: Unexpected buffer reallocation for component "
                     "type %s: consider preallocating more space ",
                     componentTypeID_);
            const components =
                max(minLength, to!size_t(allocatedSize * Policy.reallocMult));
            reserveComponentSpace(components);
            return uncommittedComponentSpace;
        }}

        alias ubyte[] function(ref ComponentBuffer, const size_t) nothrow
            nothrowFunc;
        return (cast(nothrowFunc)&implementation)(this, minLength);
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
               component.componentData.length == componentSize_,
               "Component to add has unexpected component type and/or size");

        // Ensure the (rare) case of running out of space is handled.
        ubyte[] uncommitted = forceUncommittedComponentSpace(1);
        uncommitted[0 .. componentSize_] = component.componentData[];
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
        const bytes    = componentSize_ * componentCount;
        storage_.reserve(bytes);
        storage_.growUninitialized(bytes);
        storage_[oldBytes .. $] = 0;
        allocatedComponents_ = componentCount;
    }

    /// Get the size of uncommitted (free) space in components.
    size_t uncommittedSize() @safe const pure nothrow @nogc
    {
        // The length, not capacity, counts as allocated space for this API.
        return allocatedSize - committedComponents_;
    }

    /// Get the allocated space in components.
    size_t allocatedSize() @safe const pure nothrow @nogc
    {
        // The length, not capacity, counts as allocated space for this API.
        return allocatedComponents_;
    }

    /// Get the size of a single component in bytes.
    size_t componentBytes() @safe pure nothrow const @nogc { return componentSize_; }

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
    }
}
