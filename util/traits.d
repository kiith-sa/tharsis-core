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
