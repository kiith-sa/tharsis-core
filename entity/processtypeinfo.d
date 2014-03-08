//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Analysis and type information of process() methods in Processes.
module tharsis.entity.processtypeinfo;

import std.algorithm;
import std.array;
import std.conv;
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
    alias overloads             = processOverloads!Process;
    alias RawPastTypes          = staticMap!(PastComponentTypes, overloads);
    alias AllPastComponentTypes = NoDuplicates!RawPastTypes;
}
unittest
{
    struct AComponent{enum ComponentTypeID = 1;}
    struct BComponent{enum ComponentTypeID = 2;}
    struct CComponent{enum ComponentTypeID = 3;}
    class S
    {
        void process(ref immutable(AComponent) a, ref immutable(BComponent) b){};
        void process(ref immutable(AComponent) a, ref immutable(CComponent) b){};
    }
    static assert(AllPastComponentTypes!S.length == 3);
}

/// Is the specified type an EntityAccess type?
/// 
/// (Passed to some process() functions to access entity info.)
template isEntityAccess(T)
{
    alias isEntityAccess = hasMember!(T, "isEntityAccess_");
}

/// Get past component types read by specified process() method.
template PastComponentTypes(alias ProcessFunc)
{
    mixin validateProcessMethod!ProcessFunc;
    // Get the actual component type (Param may be a slice).
    template BaseType(Param)
    {
        static assert(!isPointer!Param,
                      "Past components can't be passed by pointer");
        static if(isArray!Param) { alias BaseType = typeof(Param.init[0]); }
        else                     { alias BaseType = Param; }
    }

    // Past components are passed by const.
    alias constTypes         = ConstTypes!(ParameterTypeTuple!ProcessFunc);

    alias constComponents    = Filter!(templateNot!isEntityAccess, constTypes);
    // Get the actual component types.
    alias baseTypes          = staticMap!(BaseType, constComponents);
    // Remove qualifiers such as const.
    alias PastComponentTypes = UnqualAll!baseTypes;
}

/// Get sorted array of IDs of past component types read by a process() method.
template pastComponentIDs(alias ProcessFunc)
{
    enum pastComponentIDs = componentIDs!(PastComponentTypes!ProcessFunc);
}

/// Get the raw (with any qualifiers, as a reference, pointer or slice, as 
/// specified in the signature) future component type written by a process() 
/// method
template RawFutureComponentType(alias ProcessFunc)
{
private:
    enum paramIndex = futureComponentIndex!ProcessFunc();
    static assert(paramIndex != size_t.max,
                  "Can't get future component type of a process() method "
                  "writing no future component.");
public:
    alias RawFutureComponentType = ParameterTypeTuple!ProcessFunc[paramIndex];
}

/// Get the future component type written by a process() method.
template FutureComponentType(alias ProcessFunc)
{
private:
    alias FutureParamType = Unqual!(RawFutureComponentType!ProcessFunc);

public:

    // Get the actual component type (components may be passed by slice).
    static if(isArray!FutureParamType)
    {
        alias FutureComponentType = typeof(FutureParamType.init[0]);
    }
    else static if(isPointer!FutureParamType)
    {
        alias FutureComponentType = typeof(*FutureParamType);
    }
    else 
    {
        alias FutureComponentType = FutureParamType;
    }
}

/// Does a process() method write to a future component?
template hasFutureComponent(alias ProcessFunc)
    if(isCallable!ProcessFunc)
{
    enum hasFutureComponent = futureComponentIndex!ProcessFunc != size_t.max;
}

/// Does a Process write to some future component?
template hasFutureComponent(Process)
{
    enum hasFutureComponent = 
        __traits(compiles, Process.FutureComponent.sizeof);
}

/// Does a process() method write to a future component by pointer?
///
/// (Writing by pointer allows to null the pointer, allowing to remove/not add
/// the component into the future entity.
template futureComponentByPointer(alias ProcessFunc)
{
    enum futureComponentByPointer = 
        hasFutureComponent!ProcessFunc &&
        isPointer!(RawFutureComponentType!ProcessFunc);
}

/// If ProcessFunc writes to a future component, return its index in the 
/// parameter list. Otherwise return size_t.max.
size_t futureComponentIndex(alias ProcessFunc)()
{
    size_t result = size_t.max;
    alias ParamTypes = ParameterTypeTuple!ProcessFunc;
    foreach(idx, paramStorage; ParameterStorageClassTuple!ProcessFunc)
    {
        if(paramStorage & ParameterStorageClass.out_ ||
           (isPointer!(ParamTypes[idx]) && 
            paramStorage & ParameterStorageClass.ref_) ||
           (isArray!(ParamTypes[idx]) &&
            paramStorage & ParameterStorageClass.ref_))
        {
            assert(result == size_t.max, 
                   "process() method with multiple future components");
            result = idx;
        }
    }
    return result;
}

/// Validate a process() method.
template validateProcessMethod(alias Function)
{
    // The return type does not matter; it just allows us to call this method
    // with CTFE when this mixin is used.
    typeof(null) validate()
    {
        alias ParamTypes          = ParameterTypeTuple!Function;
        alias ParamStorageClasses = ParameterStorageClassTuple!Function;
        uint nonConstCount;
        bool[size_t] pastIDs;
        foreach(i, Param; ParamTypes)
        {
            enum storage = ParamStorageClasses[i];
            enum isSlice = isArray!Param;
            enum isPtr   = isPointer!Param;
            // Get the actual component type 
            // (the parameter may be a pointer or slice).
            static if(isSlice)    { alias Component = typeof(Param.init[0]); }
            else static if(isPtr) { alias Component = typeof(*Param.init); }
            else                  { alias Component = Param; }

            // TODO entities might also be supported later for some cases.
            assert((Unqual!Component).stringof.endsWith("Component"), 
                   "A parameter type to a process() method with name not " 
                   "ending by \"Component\": " ~ Param.stringof);

            // MultiComponents must be passed by slices.
            static if(isSlice)
            {
                assert(isMultiComponent!Component, 
                       "A non-MultiComponent passed by slice as a future "
                       "component of a process() method");
            }
            // Other component types may _not_ be passed by slices.
            else
            {
                assert(!isMultiComponent!Component, 
                       "A MultiComponent not passed by slice as a past "
                       "component of a process() method");
            }

            // Future component.
            static if(isMutable!Component) 
            {
                ++nonConstCount;
                // ref is required to allow the Process to downsize the slice.
                static if(isSlice)
                {
                    assert(storage & ParameterStorageClass.ref_,
                           "Slice for a future MultiComponent of a process() "
                           "method must be 'ref'");
                }
                // out is just to write the future component, ref pointer also
                // allows _not to write_ the component into future state.
                else
                {
                    assert((isPtr && storage & ParameterStorageClass.ref_) ||
                          (!isPtr && storage & ParameterStorageClass.out_),
                           "Future non-multi component of a process() method "
                           "must be 'out' or a 'ref' pointer");
                }
            }
            // Past component.
            else 
            {
                assert(!isPtr, "Past components must not be passed by pointer");
                assert((Component.ComponentTypeID in pastIDs) == null,
                       "Two past components of the same type (or of types "
                       "with the same ComponentTypeID) in a process() "
                       "method signature");


                // Past slices must have the default storage class so the 
                // Process may not modify them.
                static if(isSlice)
                {
                    assert(storage == ParameterStorageClass.none,
                           "Slice for a past MultiComponent of a process() "
                           "method must not be 'out', 'ref', 'scope' or "
                           "'lazy'");
                }
                // Normal past components are passed by (const) ref.
                else 
                {
                    assert(ParamStorageClasses[i] == ParameterStorageClass.ref_,
                           "Past components of a process() method must be "
                           "'ref'");
                }

                // Register this past component.
                pastIDs[Component.ComponentTypeID] = true;
            }
        }
        assert(nonConstCount <= 1,
               "A process() method with more than one future (non-const) " 
               "component type");
        return null;
    }

    enum dummy = validate();
}


/// Validate a Process type.
mixin template validateProcess(Process)
{
    // For now processes must be classes.
    static assert(is(Process == class), 
        "Processes must be classes (structs may be allowed in future)");
    alias overloads = processOverloads!Process;
    // A Process without a process() method is not a Process.
    static assert(overloads.length > 0,
        "A Process must have at least one process() method");

    // Validate the process() methods.
    // Mixins don't work in CTFE so we directly call validate().
    enum dummyValidateOverloads = {
        foreach(o; overloads) { validateProcessMethod!o.validate(); }
        return true;
        }();

    static if(hasFutureComponent!Process)
    {
        // Ensure all process() methods write the Process-specified 
        // FutureComponent.
        alias FutureComponent = Process.FutureComponent;
        enum dummyCheckFutureComponent = {
            foreach(o; overloads) 
            {
                static assert(is(FutureComponentType!o == FutureComponent),
                    "Every process() method overload of a Process with a "
                    "FutureComponent must write that FutureComponent (have "
                    "exactly one non-const reference, pointer or slice (for "
                    "MultiComponents) parameter, which must be of that future "
                    "component type). \nMethod breaking this rule: %s\n"
                    "Future component type written by that method: %s\n"
                    .format(typeof(o).stringof,
                            (FutureComponentType!o).stringof));
            }
            return true;}();
    }
    else 
    {
        // Ensure no process() methods write any FutureComponent.
        enum dummyCheckFutureComponent = {
            foreach(o; overloads) 
            {
                static assert(!hasFutureComponent!o,
                    "process() method overloads of a Process without a "
                    "FutureComponent must not write any future components "
                    "(must not have non-const reference, pointer or slice "
                    "parameters) \nMethod breaking this rule: %s\n"
                    .format(typeof(o).stringof));
            }
            return true;}();
    }
}


/// Prioritize overloads of the process() method from process P.
/// 
/// Returns: An array of 2-tuples sorted from the most specific process()
///          overload (i.e. the one that reads the most past components) to the
///          most general (reads the fewest past components).
///          The first member of each 2-tuple is a string containing 
///          comma-separated IDs of past component types the overload reads; the
///          second member is the index of the overload in processOverloads!P.
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
/// Example: if one process() method reads components A and B, another reads 
/// B and C, and an entity has components A, B and C, we don't know which 
/// overload to call. This will trigger an error, requiring the user to define 
/// another process() overload reading A, B and C. This overload will take 
/// precedence as it is unambiguosly more specific than both previous overloads.
Tuple!(string, size_t)[] prioritizeProcessOverloads(P)()
{
    // All overloads of the process() method in P.
    alias overloads = processOverloads!P;

    // Keys are component combinations handled by process() overloads, values 
    // are the indices of process() overloads handling each combination.
    size_t[immutable(ushort)[]] cases;

    // For each pair of process() overloads (even if o1 and o2 are the same):
    foreach(i1, o1; overloads) foreach(i2, o2; overloads)
    {
        // A union of IDs of the past component types read by o1 and o2.
        auto combined = pastComponentIDs!o1.setUnion(pastComponentIDs!o2)
                        .uniq.array;

        // We've already found an overload for this combination.
        if((combined in cases) != null) { continue; }

        // Find the overload handling the combined past components read by o1 
        // and o2. (If o1 and o2 are the same, this will also find the same 
        // overload).
        size_t handlerOverload = size_t.max;
        foreach(i, ids; staticMap!(pastComponentIDs, overloads))
        {
            if(ids == combined)
            {
                handlerOverload = i;
                break;
            }
        }

        assert(handlerOverload != size_t.max, "Ambigous process() "
               "overloads in %s: %s, %s. Add an overload handling "
               "past components processed by both overloads %s."
               .format(P.stringof, 
                       typeof(o1).stringof, typeof(o2).stringof, combined));

        cases[cast(immutable(ushort)[])combined] = handlerOverload;
    }

    // The result must be an ordered array.
    Tuple!(string, size_t)[] result;
    foreach(ids, overload; cases) 
    {
        assert(!result.canFind!(pair => pair[1] == overload),
               "Same overload assigned to multiple component combinations\n"
               "result: %s\n ids: %s\n overload: %s\n"
               .format(result, ids, overload));

        result ~= tuple(ids.map!(to!string).join(", "), overload); 
    }
    // Sort from most specific (reading most past components) to least specific
    // process() functions.
    result.sort!((a, b) => a[0].split(",").length > b[0].split(",").length);
    return result;
}
