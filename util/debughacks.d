//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Unsafe hacks useful only for debugging.
module tharsis.util.debughacks;


/// A writeln wrapper that can be called in @safe/pure/nothrow without complains
/// from the compiler. Should be used ONLY temporarily for fixing bugs.
@trusted pure nothrow void writelnUnsafeThrowingImpureHACK(S ...)(S args) 
{
    import std.stdio;
    (cast (void function(S) nothrow @safe pure) &writeln!S) (args);
}
unittest 
{
    @safe pure nothrow test()
    {
        writelnUnsafeThrowingImpureHACK(42, " is the answer ", 5.5f);
    }

    test();
}
