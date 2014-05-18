//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Templates extracting type information ala std.traits.
module tharsis.util.traits;


import std.string;
import std.traits;
import std.typetuple;


/// Get a compile-time tuple containing names of all fields in a struct.
template FieldNamesTuple(S)
    if(is(S == struct))
{
    /// Determine if a member with specified name is a field of S.
    template isField(string memberName)
    {
        // For some reason, checking if 'S.this.offsetof' compiles is a compiler 
        // error.
        static if(memberName == "this")
        {
            enum bool isField = false;
        }
        else 
        {
            mixin(q{enum bool isField = __traits(compiles, S.%s.offsetof);}
                  .format(memberName));
        }
    }

    alias FieldNamesTuple = Filter!(isField, __traits(allMembers, S));
}
unittest
{
    struct Test 
    {
        int fieldA;
        string fieldB;

        static bool staticField;

        void method() {}
    }

    static assert(FieldNamesTuple!Test.length == 2 &&
                  FieldNamesTuple!Test[0] == "fieldA" &&
                  FieldNamesTuple!Test[1] == "fieldB");
}

/// Get a compile-time tuple containing unqualified versions of specified types.
template UnqualAll(Types... )
{
    alias UnqualAll = staticMap!(Unqual, Types);
}

/// Get a compile-time tuple with only const/immutable types from given tuple.
template ConstTypes(ParameterTypes...)
{
    alias ConstTypes = Filter!(templateNot!isMutable, ParameterTypes);
}

/// $(D true) if $(D func) is $(D nothrow).
template isNothrow(alias func)
    if(isCallable!func)
{
    enum isNothrow = (functionAttributes!func & FunctionAttribute.nothrow_) != 0;
}

/// $(D true) if $(D func) is $(D pure).
template isPure(alias func)
    if(isCallable!func)
{
    enum isPure = (functionAttributes!func & FunctionAttribute.pure_) != 0;
}

/// $(D true) if $(D func) returns a reference to a value.
template returnsByRef(alias func)
    if(isCallable!func)
{
    enum returnsByRef = (functionAttributes!func & FunctionAttribute.ref_) != 0;
}
/// Call this to force the caller to be impure
/// (to block automatic inference of purity for functions passed to templates).
void unPurifier() @trusted nothrow
{
    static __gshared uint uglyGlobal;
    uglyGlobal += 6;
}

/// Validate signature of a method (member function) by comparing to a reference method.
///
/// Params:  T           = The type (class or struct) that has the method.
///          method      = Name of the method.
///          expectedAPI = A method with the signature we expect the validated method to 
///                        have.
///
/// To use validateMethodAPI declare a dummy method with expected signature and call
/// validateMethodAPI with the type/method we're validating and the dummy method.
/// This is usually useful when validating complex concepts such as Source or Process
/// which use compile-time polymorphism instead of interfaces and virtual methods.
/// 
/// validateMethodAPI checks that the method has the same return type and parameters
/// as the reference method. It also checks the storage classes of the parameters and
/// attributes of the method. These may not be exactly the same in the validated method
/// as in the reference method, but they must be "good enough or better".
///
/// The rules for parameter storage classes are as follows:
///
/// * If a parameter in ExpectedAPI is lazy, the parameter must be lazy.
/// * If a parameter in ExpectedAPI is not lazy, the parameter must not be lazy.
/// * If a parameter in ExpectedAPI is scope, the parameter must be scope.
/// * If a parameter in ExpectedAPI is not ref, the parameter must not be ref.
/// * If a parameter in ExpectedAPI is not out, the parameter must not be out.
///
/// The rules for function attributes:
///
/// * If ExpectedAPI is @safe/@trusted, the method must be @safe/@trusted.
/// * If ExpectedAPI is nothrow, the method must be nothrow.
/// * If ExpectedAPI is pure, the method must be pure.
/// * If ExpectedAPI returns by ref, the method must return by ref.
/// * If ExpectedAPI does not return by ref, the method must not return by ref.
///
/// Template methods:
///
/// At this moment, validateMethodAPI doesn't handle template methods. To validate at 
/// least the non-template aspects of a template method, use a concrete instantiation
/// as the $(D method) parameter, e.g. 
/// validateMethodAPI(MyStruct, "doStuff!int", doStuffReference);
///
/// Purity:
///
/// The compiler may automatically determine purity of a method passed as ExpectedAPI.
/// To ensure that the dummy method passed as ExpectedAPI is not pure when purity is not
/// required for the validated methods, call the tharsis.util.traits.unPurifier()
/// function from the dummy method.
string validateMethodAPI(T, string method, alias ExpectedAPI)()
{
    // TODO handle template methods separately and remove the findSplit hack below.
    const type = T.stringof;
    // If the method is an instantation of a template method the member will be without
    // the template parameter.
    if(!__traits(hasMember, T, method.findSplit("!")[0]))
    {
        return "Type %s does not have expected method '%s'\n".format(type, method);
    }

    mixin(q{
    alias Method = T.%s;
    }.format(method));

    alias ExpectedRet            = ReturnType!ExpectedAPI;
    alias ExpectedParams         = ParameterTypeTuple!ExpectedAPI;
    alias StorageClasses         = ParameterStorageClassTuple!Method;
    alias ExpectedStorageClasses = ParameterStorageClassTuple!ExpectedAPI;

    string[] lines;
    static if(!is(ReturnType!Method == ExpectedRet))
    {
        lines ~= "must return an instance of %s".format(ExpectedRet.stringof);
    }
    static if(!is(ParameterTypeTuple!Method == ExpectedParams))
    {
        lines ~= "must have the following parameters: " ~ ExpectedParams.stringof;
    }
    else foreach(i, expected; ExpectedStorageClasses)
    {
        alias ParameterStorageClass STC;
        auto storageClass = StorageClasses[i];
        if(storageClass == expected) { continue; }

        // Lazy might evaluate when not expected so we strictly want the API to match.
        auto isLazy = expected & STC.lazy_;
        // If we expect scope, the method must use scope as otherwise it may escape 
        // references.
        auto isScope = expected & STC.scope_;
        // If we expect out or ref, it's OK to not use them; the method might not want
        // to overwrite the caller's values. But if we _don't_ expect them, we must
        // enforce they are not used as the method might unexpectedly modify the 
        // caller's values.
        auto isOut  = expected & STC.out_;
        auto isRef  = expected & STC.ref_;

        if((storageClass & STC.lazy_) != isLazy)
        {
            lines ~= "parameter %s must%s be lazy".format(i, isLazy ? "" : " not");
        }
        if(!(storageClass & STC.scope_) && isScope)
        {
            lines ~= "parameter %s must be scope";
        }
        if((storageClass & STC.out_) && !isOut)
        {
            lines ~= "parameter %s must not be out";
        }
        if((storageClass & STC.ref_) && !isRef)
        {
            lines ~= "parameter %s must not be ref";
        }
    }

    static if(!isSafe!Method && isSafe!ExpectedAPI)
    {
        lines ~= "must be @safe or @trusted";
    }
    static if(!isNothrow!Method && isNothrow!ExpectedAPI)
    {
        lines ~= "must be nothrow";
    }
    static if(!isPure!Method && isPure!ExpectedAPI)
    {
        lines ~= "must be pure";
    }
    static if(returnsByRef!Method != returnsByRef!ExpectedAPI)
    {
        lines ~= "must%s return by ref".format(returnsByRef!ExpectedAPI ? "" : " not");
    }

    string base = "Invalid API: member %s of type %s: ".format(method, type);
    return lines.empty ? null : base ~ "\n" ~ lines.join("\n") ~ "\n\n";
}
