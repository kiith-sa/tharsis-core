//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// A manually allocated dynamic array.
module tharsis.util.mallocarray;


import core.memory;

import std.algorithm;
import std.traits;
import std.typecons;

import tharsis.util.alloc;
import tharsis.util.noncopyable;

/// A manually allocated dynamic array.
///
/// Must not be used for types that depend on the GC. E.g. string data members
/// might be prematurely deleted as they are _not_ visible to the GC.
///
/// This is pretty much a placeholder until Phobos gets allocators working and 
/// fixes its containers.
///
/// Params: T       = The type stored in the array.
///         forceGC = Force the garbage collector to scan this array for 
///                   pointers (regardless of what type T is)?
struct MallocArray(T, Flag!"ForceGC" forceGC = No.ForceGC)
    if(isBasicType!T || is(T == struct))
{
private:
    /// Internally allocated data.
    ubyte[] data_;

public:
    /// Must NOT be used directly. Will be made private once a DMD bug is fixed.
    T[] usedData_;

    /// Use plain D array features as a base.
    alias usedData_ this;

    /// No accidental assignments from an array.
    @disable void opAssign(T[] array);

    /// No copying (we simply don't implement that stuff yet).
    mixin(NonCopyable);

    /// Destroy the MallocArray, freeing memory.
    @trusted nothrow ~this()
    {
        clear();
        if(data_ != []) 
        {
            // True if the GC needs to scan this type.
            if(forceGC || typeid(T).flags)
            {
                GC.removeRange(cast(void*)data_.ptr); 
            }
            freeMemory(cast(void[])data_); 
        }
        usedData_ = null;
        data_     = null;
    }

    /// Append an element to the MallocArray.
    ///
    /// Will reallocate if out of space.
    void opCatAssign(U : T)(U element) @trusted nothrow
        if(isImplicitlyConvertible!(T, U))
    {
        const oldLength      = this.length;
        const oldLengthBytes = oldLength * T.sizeof;
        if(data_.length == oldLengthBytes) { reserve((data_.length + 8) * 2); }

        usedData_ = (cast(T[])data_)[0 .. oldLength + 1];
        usedData_[oldLength] = element;
        assert(this.length == oldLength + 1, "Unexpected length after append");
    }

    import tharsis.prof;
    
    /** Reserve (preallocate) space for more elements.
     * 
     * Params:  items    = Minimum of items to preallocate space for. If less than
     *                     the current capacity, this call is ignored. The actual size
     *                     of allocated space might be higher.
     *          profiler = Optional profiler to profile overhead.
     */
    void reserve(const size_t items, Profiler profiler = null) @trusted nothrow
    {
        auto zone = Zone(profiler, "MallocArray.reserve()");
        const bytesNeeded = T.sizeof * items;
        if(data_.length >= bytesNeeded) { return; }

        // Ensure that even if reserve() is called with gradually increasing sizes we
        // don't always need to allocate.
        const bytesAlloc = max(bytesNeeded, data_.length * 2);

        {
            auto zoneAlloc = Zone(profiler, "allocateMemory()");
            data_ = cast(ubyte[])allocateMemory(bytesAlloc, typeid(T));
        }

        // True if the GC needs to scan this type.
        if(forceGC || typeid(T).flags)
        {
            auto zoneAddRange = Zone(profiler, "GC.addRange()");
            GC.addRange(cast(void*)data_.ptr, data_.length); 
        }

        auto oldUsedData = usedData_;
        usedData_ = (cast(T[])data_)[0 .. this.length];
        {
            auto zoneCopy = Zone(profiler, "copy");
            // Avoid postblits or copy-ctors.
            (cast(ubyte[])usedData_)[] = (cast(ubyte[])oldUsedData)[];
        }
        // True if the GC needs to scan this type.
        if(forceGC || typeid(T).flags)
        {
            auto zoneRemoveRange = Zone(profiler, "GC.removeRange()");
            GC.removeRange(cast(void*)oldUsedData.ptr); 
        }

        if(oldUsedData !is null)
        {
            auto zoneFree = Zone(profiler, "freeMemory()");
            freeMemory(cast(void[])oldUsedData);
        }
    }

    /// Grow up to currently allocated capacity without initializing data,
    ///
    /// Params:  items = Length to grow to, in items. Must be greater than the 
    ///                  current length.
    ///
    /// Can only grow to allocated capacity.
    ///
    /// See_Also: reserve, capacity
    void growUninitialized(const size_t items) pure nothrow
    {
        assert(items >= this.length, 
               "Calling grow() with smaller than current size");
        auto allData = cast(T[])data_;
        assert(items <= allData.length, 
               "Calling growUninitialized with size greater than reserved "
               "space. Call reserve() first.");
        usedData_ = allData[0 .. items];
    }

    /// Clear the MallocArray, destroying all elements without deallocating.
    void clear() @trusted pure nothrow
    {
        usedData_.destroy();
        usedData_ = cast(T[])data_[0 .. 0];
    }

    /// Get the number of items this MallocArray can store without reallocating.
    size_t capacity() @safe pure nothrow const
    {
        return data_.length / usedData_.sizeof;
    }

    /// Is the array empty?
    bool empty() @safe pure nothrow const
    {
        return usedData_.length == 0;
    }
}


