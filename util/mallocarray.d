//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// A manually allocated dynamic array.
module tharsis.util.mallocarray;


import std.algorithm;
import std.traits;

import tharsis.util.alloc;

/// A manually allocated dynamic array.
///
/// Must not be used for types that depend on the GC. E.g. string data members
/// might be prematurely deleted as they are _not_ visible to the GC.
///
/// This is pretty much a placeholder until Phobos gets allocators working and 
/// fixes its containers.
struct MallocArray(T)
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

    /// No copying.
    @disable this(this);

    /// Destroy the MallocArray, freeing memory.
    @trusted nothrow ~this()
    {
        clear();
        freeMemory(cast(void[])data_, typeid(T));
        usedData_ = null;
        data_     = null;
    }

    /// Append an element to the MallocArray.
    ///
    /// Will reallocate if out of space.
    void opCatAssign(U : T)(U element) @trusted nothrow
        if(isImplicitlyConvertible!(T, U))
    {
        const oldLength = this.length;
        if(data_.length == oldLength) { reserve((data_.length + 8) * 2); }

        usedData_ = (cast(T[])data_)[0 .. oldLength + 1];
        usedData_[oldLength] = element;
        assert(this.length == oldLength + 1, "Unexpected length after append");
    }

    /// Preallocate space for more elements.
    /// 
    /// Params:  items = Number of items to preallocate space for. If less than
    ///                  the current capacity, this call is ignored.
    void reserve(const size_t items) @trusted nothrow
    {
        const bytes = T.sizeof * items;
        if(data_.length >= items) { return; }
        data_ = cast(ubyte[])allocateMemory(bytes, typeid(T));
        auto oldUsedData = usedData_;
        usedData_ = (cast(T[])data_)[0 .. this.length];
        // Avoid postblits or copy-ctors.
        (cast(ubyte[])usedData_)[] = (cast(ubyte[])oldUsedData)[];
        freeMemory(cast(void[])oldUsedData, typeid(T));
    }

    /// Clear the MallocArray, destroying all elements without deallocating.
    void clear() @trusted pure nothrow
    {
        usedData_.destroy();
        usedData_ = cast(T[])data_[0 .. 0];
    }

    /// Get the number of items this MallocArray can store without reallocating.
    size_t capacity() @safe pure nothrow
    {
        return data_.length / usedData_.sizeof;
    }
}


