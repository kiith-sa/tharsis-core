//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// An extension to std.typetuple.
module tharsis.util.typetuple;


public import std.typetuple;


/** Create a tuple of indices from 0 to the length of passed tuple.
 *
 * Useful in combination with std.traits.staticMap - mapping indices to results of a more
 * complex template, which, having index as a template argument, can index multiple enum
 * arrays or TypeTuples.
 *
 * For an example of where this is useful, see
 * tharsis.entity.processtypeinfo.processMethodParamInfo.
 *
 * Examples:
 * --------------------
 * static assert(tupleIndices!(TypeTuple!(int, long, char)) == TypeTuple!(0, 1, 2));
 * --------------------
 */
template tupleIndices(Head, Tail ...)
{
    static if(Tail.length == 0)
    {
        alias tupleIndices = TypeTuple!(0);
    }
    else
    {
        alias tailResult   = tupleIndices!Tail;
        alias tupleIndices = TypeTuple!(tailResult, tailResult[$ - 1] + 1);
    }
}

/// Generate a compile-time sequence TypeTuple of integers from min to max.
template Sequence(int min, int max)
{
    static assert(min <= max, "min must not be greater than max");
    static if(min == max)
    {
        alias Sequence = TypeTuple!();
    }
    else
    {
        alias Sequence = TypeTuple!(min, Sequence!(min + 1, max));
    }
}
