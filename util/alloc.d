//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Overridable allocation/deallocation functions for Tharsis.
module tharsis.util.alloc;


import core.stdc.stdlib;


/// The default allocation function (just a nothrow malloc wrapper).
void[] nothrowMalloc(const size_t bytes, TypeInfo type) nothrow
{
    return (cast(void* function(const size_t) nothrow)
            &core.stdc.stdlib.malloc)(bytes)[0 .. bytes];
}

/// The default deallocation function (just a nothrow free wrapper).
void nothrowFree(void[] data) nothrow 
{
    (cast(void function(void*) nothrow)&core.stdc.stdlib.free)(data.ptr);
}

/// The allocation function used to allocate most memory used by Tharsis.
/// 
/// Can be overridden to point to another function, but this can only be done at 
/// startup before Tharsis allocates anything. In that case, freeMemory must be 
/// overridden as well.
///
/// Params: bytes = The number of bytes to allocate.
///         type  = Type information about the allocated type
///                 (useful for debugging/diagnostics).
///
/// Returns: Allocated data as a void[] array.
__gshared void[] function (const size_t bytes, TypeInfo) nothrow allocateMemory 
    = &nothrowMalloc;

/// The free function used to free most memory used by Tharsis.
///
/// Can be overridden to point to another function, but this can only be done at 
/// startup before Tharsis allocates anything. In that case, freeMemory must be 
/// overridden as well.
///
/// Params: data = The data to deallocate.
__gshared void function (void[] data) nothrow freeMemory = &nothrowFree;
