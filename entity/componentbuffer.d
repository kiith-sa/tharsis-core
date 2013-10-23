//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Per-component type buffers.
module tharsis.entity.componentbuffer;


import std.stdio;

import tharsis.util.mallocarray;

/// A buffer storing all (either past or future) components of one component 
/// type.
///
/// The components are stored as plain bytes. Components are written by 
/// accessing unused memory with unusedSpace(), writing the components, and 
/// "comitting" them with commitComponents(). If there's not enough space for 
/// new components, the buffer must be reallocated with 
/// reallocateComponentSpace().
struct ComponentBuffer
{
private:
    /// Is this ComponentBuffer enabled?
    ///
    /// (I.e. is there a component type that uses this ComponentBuffer?)
    bool enabled_ = false;

    /// Size (in bytes) of a single component in this buffer.
    size_t componentSize_ = size_t.max;

    /// The buffer itself. Stores components without any padding.
    MallocArray!ubyte storage_;

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
    /// Params:  componentSize = Size of a component of the component type.
    void enable(const size_t componentSize) @safe pure nothrow
    {
        assert(!enabled_, "Trying to enable a component buffer that's " 
                          "already enabled. Maybe two components with "
                          "the same ComponentTypeID?");
        componentSize_ = componentSize;
        enabled_       = true;
    }

    /// Is this ComponentBuffer enabled?
    bool enabled() @safe pure nothrow { return enabled_; }

    /// Get the memory that's not used yet. 
    ///
    /// Components can be written to this memory, and then committed using 
    /// commitComponents().
    ubyte[] uncomittedComponentSpace() pure nothrow @safe
    {
        assert(enabled_, "Can't get data of a buffer that is not enabled");
        return storage_[componentSize_ * committedComponents_ .. $];
    }

    /// Get the memory used for the _committed_ components, i.e. those that 
    /// have been written and exist as a part of one or another entity.
    const(ubyte)[] comittedComponentSpace() const pure nothrow @safe
    {
        assert(enabled_, "Can't get data of a buffer that is not enabled");
        return storage_[0 .. componentSize_ * committedComponents_];
    }

    /// Ditto.
    immutable(ubyte)[] comittedComponentSpace() immutable pure nothrow @safe
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
    void commitComponents(const size_t count) @safe nothrow
    {
        assert(enabled_, 
               "Can't commit components to a buffer that's not enabled");
        committedComponents_ += count;
    }

    /// Reserve space for more components.
    ///
    /// Must be called if unusedComponentSpace() is not long enough to store 
    /// components we need to add.
    ///
    /// Params: componentCounts = The number of components to allocate space 
    ///                           for.
    void reallocateComponentSpace(const size_t componentCount) @trusted nothrow
    {
        assert(enabled_, 
                "Calling reallocateComponentSpace on a non-enabled buffer");
        const oldBytes    = storage_.length;
        const bytesNeeded = componentSize_ * componentCount;
        if(oldBytes < bytesNeeded) 
        {
            storage_.reserve(bytesNeeded);
            storage_.growUninitialized(bytesNeeded);
            storage_[oldBytes .. $] = 0;
        }
    }

    /// Get the number of components committed (written) so far.
    size_t committedComponentCount() @safe pure nothrow const 
    {
        assert(enabled_, 
               "Can't get used component count from a non-enabled buffer");
        return committedComponents_;
    }

    /// Clear a ComponentBuffer before use as a future component buffer
    /// to catch any bugs with reading no longer used data.
    ///
    /// This exists only to catch bugs, and can be removed if the overhead
    /// is too high.
    void reset() @safe pure nothrow
    {
        assert(enabled_, "Can't reset a non-enabled buffer");
        storage_[]           = 0;
        committedComponents_ = 0;
    }
}



/// A buffer storing the component counts of one component type for all 
/// (either past or future) entities.
///
/// The component counts are stored with the same order as past/future enities
/// in EntityManager, so the component count of an entity can be accessed using
/// the index of the entity.
struct ComponentCountBuffer(Policy)
{
    /// Shortcut alias.
    alias Policy.ComponentCount ComponentCount;
private:
    /// Is this ComponentCountBuffer enabled?
    ///
    /// (I.e. is there a component type that uses this ComponentCountBuffer?)
    bool enabled_ = false;

    /// Stores component counts for entities at the same indices.
    ///
    /// I.e. componentsPerEntity_[i] is the number of components of the type 
    /// corresponding to this buffer for entity at index i in EntityManager.
    MallocArray!ComponentCount componentsPerEntity_;

    /// Disable copying.
    @disable void opAssign(ref ComponentBuffer);
    @disable this(this);

public:
    /// Destroy this ComponentCountBuffer.
    ~this()
    {
        // Not really necessary, just to ease bug detection.
        if(enabled_) { reset(); }
        componentsPerEntity_.destroy();
    }

    /// Enable the ComponentCountBuffer, meaning some component type uses it.
    void enable() @safe pure nothrow
    {
        assert(!enabled_, "Trying to enable a component count buffer that's " 
                          "already enabled. Maybe two components with "
                          "the same ComponentTypeID?");
        enabled_ = true;
    }

    /// Is this ComponentCountBuffer enabled?
    bool enabled() @safe pure nothrow { return enabled_; }

    /// Set the number of components in entity at specified index.
    ///
    /// Params: entityIdx = Index of the entity in past/future entities in 
    ///                     EntityManager.
    ///         count     = Number of components of the type corresponding 
    ///                     to this buffer in the entity.
    void setComponentsInEntity
        (const size_t entityIdx, const ComponentCount count) @safe nothrow
    {
        assert(enabled_, 
               "Can't commit components to a buffer that's not enabled");
        componentsPerEntity_[entityIdx] = count;
    }

    /// Get the number of components in entity at specified index.
    ///
    /// Params:  entityIdx = Index of the entity in past/future entities in 
    ///                      EntityManager.
    ///
    /// Returns: Number of components of the type corresponding to this buffer 
    ///          in the entity.
    ComponentCount componentsInEntity(const size_t entityIdx) 
        const @safe pure nothrow
    {
        assert(enabled_, 
               "Can't get components per entity from a non-enabled buffer");
        return componentsPerEntity_[entityIdx];
    }

    /// Grow the number of entities this buffer stores component counts for.
    ///
    /// Can only be used to _increase_ the number of entities. Component counts 
    /// for all added entities are set to zero. Used by EntityManager e.g. after 
    /// determining the number of future entities and before adding newly 
    /// created entities.
    ///
    /// Params:  count = The new number of entities. Must be greater than the 
    ///                  current entity count (set by reset or growEntityCount).
    void growEntityCount(const size_t count) @safe nothrow
    {
        assert(enabled_, "Can't grow entity count in a non-enabled buffer");

        componentsPerEntity_.reserve(count);
        const oldSize = componentsPerEntity_.length;
        componentsPerEntity_.growUninitialized(count);
        componentsPerEntity_[oldSize .. $] = cast(ComponentCount)0;
    }

    /// Reset the buffer, setting the entity count to 0.
    /// 
    /// Called for future components before starting a frame to reuse memory.
    /// Unlike ComponentBuffer.reset(), this is necessary, not just for 
    /// debugging.
    void reset() @safe pure nothrow
    {
        assert(enabled_, "Can't reset a non-enabled buffer");
        componentsPerEntity_.clear();
    }
}
