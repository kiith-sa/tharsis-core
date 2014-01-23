//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// A dynamic array that uses stack for small sizes.
module tharsis.util.stackbuffer;


import std.traits;

import tharsis.util.alloc;


/// An array that uses stack storage (avoiding allocation overhead) if its 
/// length is short and heap (manual allocation) if its length is long.
///
/// Params: T            = The type stored in the array.
///         maxStackSize = If the array is larger than this, it is allocated on
///                        the heap.
///
/// Currently only supports value types without destructors.
/// This may be changed in future.
struct StackBuffer(T, size_t maxStackSize)
    if(!hasElaborateDestructor!T)
{
private:
    /// The stack storage used if the size of the array is <= maxStackSize.
    T[maxStackSize] stackBuffer_;

public:
    /// The buffer itself from the user's point of view.
    ///
    /// If the length of the array is less or equal to maxStackSize, this is a
    /// slice into stackBuffer_. Otherwise this is a malloc-allocated array.
    T[] self_;

    /// Alias this to make the buffer behave as a slice.
    alias self_ this;

    /// Disable any slice operations that may assume a GC-allocated array.
    ///
    /// In future, these may be redefined for more complete functionality.
    @disable this();
    @disable this(this);
    @disable void opAssign(StackBuffer);
    @disable void length(size_t);
    @disable void opCatAssign(StackBuffer);
    @disable void opCatAssign(T);
    @disable void opCat(StackBuffer);
    @disable void opCat(T);

    /// Construct a StackBuffer of specified size filled with T.init .
    this(size_t size) @trusted nothrow
    {
        self_ = size > maxStackSize ? cast(T[])nothrowMalloc(size, typeid(T))
                                    : stackBuffer_[0 .. size];
        self_[] = T.init;
    }

    /// Destroy a StackBuffer, freeing heap memory if longer than maxStackSize.
    @trusted nothrow ~this()
    {
        if(self_.ptr !is stackBuffer_.ptr)
        {
            nothrowFree(self_);
        }
    }
}

