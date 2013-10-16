//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.entity.processtypeinfo;

import std.algorithm;
import std.string;
import std.traits;
import std.typecons;
import std.typetuple;

import tharsis.entity.componenttypeinfo;
import tharsis.util.bitmanip;
import tharsis.util.traits;


/// Get all overloads of the process() method in a given Process type.
template processOverloads(Process)
{
    alias processOverloads = MemberFunctionsTuple!(Process, "process");
}
unittest 
{
    class P
    {
        void process(int a, float b)   {}
        void process(float a, float b) {}
    }
    static assert(processOverloads!P.length == 2);
}

/// Get all past component types read by process() methods of a process.
template AllPastComponentTypes(Process)
{
    alias AllPastComponentTypes =
        NoDuplicates!(staticMap!(PastComponentTypes, processOverloads!Process));
}
unittest
{
    struct AComponent{}
    struct BComponent{}
    struct CComponent{}
    class S
    {
        void process(ref immutable(AComponent) a, ref immutable(BComponent) b){};
        void process(ref immutable(AComponent) a, ref immutable(CComponent) b){};
    }
    static assert(AllPastComponentTypes!S.length == 3);
}

/// Get past component types read by specified process() method.
template PastComponentTypes(alias ProcessFunc)
    if(isValidProcessMethod!ProcessFunc)
{
    alias PastComponentTypes =
        UnqualAll!(ConstTypes!(ParameterTypeTuple!ProcessFunc));
}

/// Get a 64bit bitmask specifying past component types read by a process() method.
template pastComponentFlags(alias ProcessFunc)
{
    enum pastComponentFlags = ComponentFlags!(PastComponentTypes!ProcessFunc);
}

/// Get the future component type written by a process() method.
template FutureComponentType(alias ProcessFunc)
{
private:
    enum paramIndex = futureComponentIndex!ProcessFunc();
    static assert(paramIndex != size_t.max,
                  "Can't get future component type of a process() method "
                  "writing no future component.");
public:
    alias FutureComponentType =
        Unqual!((ParameterTypeTuple!ProcessFunc)[paramIndex]);
}

/// Does a process() method write to a future component?
template hasFutureComponent(alias ProcessFunc)
{
    enum hasFutureComponent = futureComponentIndex!ProcessFunc != size_t.max;
}

/// Does a process() method write to a future component by pointer?
///
/// (Writing by pointer allows to null the pointer, allowing to remove/not add
/// the component into the future entity.
template futureComponentByPointer(alias ProcessFunc)
{
    enum futureComponentByPointer = hasFutureComponent!ProcessFunc &&
                                    isPointer!(FutureComponentType!ProcessFunc);
}

/// If ProcessFunc writes to a future component, return its index in the 
/// parameter list. Otherwise return size_t.max.
size_t futureComponentIndex(alias ProcessFunc)()
{
    size_t result = size_t.max;
    foreach(idx, paramStorage; ParameterStorageClassTuple!ProcessFunc)
    {
        if(paramStorage & ParameterStorageClass.out_)
        {
            assert(result == size_t.max, 
                   "process() function with multiple future components");
            result = idx;
        }
    }
    return result;
}


/// Is specified method a valid process() method?
///
/// Format of process() methods of a Process is not yet finalized.
template isValidProcessMethod(alias Function)
{
    enum isValidProcessMethod = validate();

    //TODO finish once the process() function format stabilizes.
    bool validate()
    {
        alias args              = ParameterTypeTuple!Function;
        alias argStorageClasses = ParameterStorageClassTuple!Function;
        uint nonConstCount;
        foreach(i, arg; args)
        {
            /*
            assert((Unqual!arg).stringof.endsWith("Component"), 
                   "A parameter type to a process() function with name not " 
                   "ending by \"Component\": " ~ arg.stringof);
            */
            if(isMutable!arg) 
            {
                ++nonConstCount;
                assert(argStorageClasses[i] == ParameterStorageClass.out_,
                       "Output component of a process() function must be 'out'");
                //TODO allowing access by pointer here.
            }
            else 
            {
                assert(argStorageClasses[i] == ParameterStorageClass.ref_,
                       "Input components of a process() function must be 'ref'");
            }
        }
        assert(nonConstCount <= 1,
               "A process() function with more than one output (non-const) " 
               "component type");
        return true;
    }
}

/// Prioritize overloads of the process() function from process P.
/// 
/// Returns: An array of 2-tuples sorted from the most specific process()
///          overload (i.e. the one that reads the most past components) to the
///          most general (reads the fewest past components).
///          Each 2-tuple consists of a 64-bit mask specifying which past 
///          components the overload reads, and the index of the overload in
///          processOverloads!P.
///
/// Note: 
/// 
/// All process overloads in a Process write to the same future component but
/// may read different past components. 
/// 
/// Which overload to call is ambiguous if there are two overloads with 
/// different past components but no overload handling the union of these 
/// components, since there might be an entity with components matching both 
/// overloads.
/// 
/// Example: if one process() function reads components A and B, another reads 
/// B and C, and an entity has components A, B and C, we don't know which 
/// overload to call. This will trigger an error, requiring the user to define 
/// another process() overload reading A, B and C. This overload will take 
/// precedence as it is unambiguosly more specific than both previous overloads.
Tuple!(ulong, size_t)[] prioritizeProcessOverloads(P)()
{
    // All overloads of the process() function in P.
    alias overloads = processOverloads!P;
    // Keys are component combinations handled by process() overloads, values 
    // are the indices of process() overloads handling each combination.
    size_t[ulong] cases;

    // For each pair of process() overloads (even if o1 and o2 are the same):
    foreach(i1, o1; overloads) foreach(i2, o2; overloads)
    {
        // A bit mask representing the union of the past components read 
        // by o1 and o2.
        const combined = pastComponentFlags!o1 | pastComponentFlags!o2;
        // We've already found an overload for this combination.
        if((combined in cases) != null) { continue; }

        // Find the overload handling the combined past components read by o1 
        // and o2. (If o1 and o2 are the same, this will also find the same 
        // overload).
        size_t handlerOverload = size_t.max;
        foreach(i, mask; staticMap!(pastComponentFlags, overloads))
        {
            if((mask.userComponents) == combined)
            {
                handlerOverload = i;
                break;
            }
        }

        assert(handlerOverload != size_t.max, "Ambigous process() "
               "overloads in %s: %s, %s. Add an overload handling "
               "past components processed by both overloads."
               .format(P.stringof, 
                       typeof(o1).stringof, typeof(o2).stringof));

        cases[combined] = handlerOverload;
    }

    // The result must be an ordered array.
    Tuple!(ulong, size_t)[] result;
    foreach(mask, overload; cases) { result ~= tuple(mask, overload); }
    // Sort from most specific (reading most past components) to least specific
    // process() functions.
    result.sort!((a, b) => countBitsSet(a[0]) > countBitsSet(b[0]));
    return result;
}
