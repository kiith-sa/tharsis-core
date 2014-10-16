//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Extensions for std.random.
module tharsis.std.random;

public import std.random;


import std.range;

/**
Covers a given range $(D r) in a random manner, i.e. goes through each
element of $(D r) once and only once, just in a random order. $(D r)
must be a random-access range with length.

If no random number generator is passed to $(D randomCover), the
thread-global RNG rndGen will be used internally.

Example:
----
int[] a = [ 0, 1, 2, 3, 4, 5, 6, 7, 8 ];
foreach (e; randomCover(a))
{
    writeln(e);
}
----

$(B WARNING:) If an alternative RNG is desired, it is essential for this
to be a $(I new) RNG seeded in an unpredictable manner. Passing it a RNG
used elsewhere in the program will result in unintended correlations,
due to the current implementation of RNGs as value types.

Example:
----
int[] a = [ 0, 1, 2, 3, 4, 5, 6, 7, 8 ];
foreach (e; randomCover(a, Random(unpredictableSeed)))  // correct!
{
    writeln(e);
}

foreach (e; randomCover(a, rndGen))  // DANGEROUS!! rndGen gets copied by value
{
    writeln(e);
}

foreach (e; randomCover(a, rndGen))  // ... so this second random cover
{                                    // will output the same sequence as
    writeln(e);                      // the previous one.
}

----

These issues will be resolved in a second-generation std.random that
re-implements random number generators as reference types.

Usage without GC:

By default, $(D randomCover()) allocates an internal buffer of bool to keep track of which
elements of the range were chosen and which were not. To avoid this allocation, the buffer
can be passed through an optional bool[] randomCover() parameter (which must have the same
length as the range to cover).

Example:
----
int[] a = [ 0, 1, 2, 3, 4, 5, 6, 7, 8 ];
bool[] chosenBuf = new bool[a.length];

foreach (e; randomCover(a, chosenBuf))
{
    writeln(e);
}

foreach (e; randomCover(a, Random(unpredictableSeed)))
{
    writeln(e);
}
----
 */
struct RandomCover(Range, UniformRNG = void)
    if (isRandomAccessRange!Range && (isUniformRNG!UniformRNG || is(UniformRNG == void)))
{
    private Range _input;
    private bool[] _chosen;
    private size_t _current;
    private size_t _alreadyChosen = 0;

    static if (is(UniformRNG == void))
    {
        this(Range input, bool[] chosenBuffer = null)
        {
            _input = input;
            _alreadyChosen = 0;
            if(chosenBuffer is null)
            {
                _chosen.length = _input.length;
            }
            else
            {
                assert(chosenBuffer.length == input.length,
                       "chosenBuffer must have the same length as input");
                _chosen = chosenBuffer;
                _chosen[] = false;
            }
        }
    }
    else
    {
        private UniformRNG _rng;

        this(Range input, ref UniformRNG rng, bool[] chosenBuffer = null)
        {
            _input = input;
            _rng = rng;
            _alreadyChosen = 0;
            if(chosenBuffer is null)
            {
                _chosen.length = _input.length;
            }
            else
            {
                assert(chosenBuffer.length == input.length,
                       "chosenBuffer must have the same length as input");
                _chosen = chosenBuffer;
                _chosen[] = false;
            }
        }

        this(Range input, UniformRNG rng, bool[] chosenBuffer = null)
        {
            this(input, rng, chosenBuffer);
        }
    }

    static if (hasLength!Range)
    {
        @property size_t length()
        {
            if (_alreadyChosen == 0)
            {
                return _input.length;
            }
            else
            {
                return (1 + _input.length) - _alreadyChosen;
            }
        }
    }

    @property auto ref front()
    {
        if (_alreadyChosen == 0)
        {
            _chosen[] = false;
            popFront();
        }
        return _input[_current];
    }

    void popFront()
    {
        if (_alreadyChosen >= _input.length)
        {
            // No more elements
            ++_alreadyChosen; // means we're done
            return;
        }
        size_t k = _input.length - _alreadyChosen;
        size_t i;
        foreach (e; _input)
        {
            if (_chosen[i]) { ++i; continue; }
            // Roll a dice with k faces
            static if (is(UniformRNG == void))
            {
                auto chooseMe = uniform(0, k) == 0;
            }
            else
            {
                auto chooseMe = uniform(0, k, _rng) == 0;
            }
            assert(k > 1 || chooseMe);
            if (chooseMe)
            {
                _chosen[i] = true;
                _current = i;
                ++_alreadyChosen;
                return;
            }
            --k;
            ++i;
        }
    }

    static if (isForwardRange!UniformRNG)
    {
        @property typeof(this) save()
        {
            auto ret = this;
            ret._input = _input.save;
            ret._rng = _rng.save;
            return ret;
        }
    }

    @property bool empty() { return _alreadyChosen > _input.length; }
}

/// Ditto
auto randomCover(Range, UniformRNG)(Range r, auto ref UniformRNG rng, bool[] chosenBuffer = null)
    if (isRandomAccessRange!Range && isUniformRNG!UniformRNG)
{
    return RandomCover!(Range, UniformRNG)(r, rng, chosenBuffer);
}

/// Ditto
auto randomCover(Range)(Range r, bool[] chosenBuffer = null)
    if (isRandomAccessRange!Range)
{
    return RandomCover!(Range, void)(r);
}

unittest
{
    int[] a = [ 0, 1, 2, 3, 4, 5, 6, 7, 8 ];
    import std.typetuple: TypeTuple;

    foreach (UniformRNG; TypeTuple!(void, PseudoRngTypes))
    {
        static if (is(UniformRNG == void))
        {
            auto rc = randomCover(a);
            static assert(isInputRange!(typeof(rc)));
            static assert(!isForwardRange!(typeof(rc)));
        }
        else
        {
            auto rng = UniformRNG(unpredictableSeed);
            auto rc = randomCover(a, rng);
            static assert(isForwardRange!(typeof(rc)));
            // check for constructor passed a value-type RNG
            auto rc2 = RandomCover!(int[], UniformRNG)(a, UniformRNG(unpredictableSeed));
            static assert(isForwardRange!(typeof(rc2)));
        }

        int[] b = new int[9];
        uint i;
        foreach (e; rc)
        {
            //writeln(e);
            b[i++] = e;
        }
        sort(b);
        import std.conv: text;
        
        assert(a == b, text(b));


        bool[] chosenBuf = new bool[a.length];

        static if (is(UniformRNG == void))
        {
            auto rcNoGC = randomCover(a, chosenBuf);
        }
        else
        {
            auto rcNoGC = randomCover(a, rng, chosenBuf);
        }

        b[] = 0;
        i = 0;
        foreach (e; rcNoGC)
        {
            b[i++] = e;
        }

        sort(b);
        assert(a == b, text(b));
    }
}
