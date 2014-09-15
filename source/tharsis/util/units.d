//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Memory units (e.g. bytes, kilobytes).
module tharsis.util.units;


/// Enumerates possible memory units.
enum MemoryUnit: ulong
{
    B = 1,
    kiB = 1024 * B,
    MiB = 1024 * kiB,
    GiB = 1024 * MiB,
    TiB = 1024 * GiB
}

/// Represents size of a memory area (e.g. how many megabytes).
struct MemorySize(MemoryUnit baseUnit)
{
    /// Memory size in units specified by baseUnit.
    double size;
    alias size this;

    /// Construct a MemorySize by converting from a size in bytes.
    this(size_t bytes) @safe pure nothrow @nogc
    {
        size = cast(double)bytes / baseUnit;
    }
}

/// Aliases for memory sizes using various units.
alias Bytes  = MemorySize!(MemoryUnit.B);
/// Ditto.
alias KBytes = MemorySize!(MemoryUnit.kiB);
/// Ditto.
alias MBytes = MemorySize!(MemoryUnit.MiB);
/// Ditto.
alias GBytes = MemorySize!(MemoryUnit.GiB);
/// Ditto.
alias TBytes = MemorySize!(MemoryUnit.TiB);
