//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Type information about a component type.
module tharsis.entity.componenttypeinfo;


import std.algorithm;
import std.stdio;
import std.string;
import std.typetuple;

import tharsis.util.traits;


/// Maximum number of component types that can be defined by the user.
enum maxUserComponentTypes = 60;

import tharsis.entity.lifecomponent;
/// A tuple of all builtin component types.
alias TypeTuple!(LifeComponent) BuiltinComponents;

/// Return a component mask with only the user component types from given mask.
ulong userComponents(const ulong mask) @safe pure nothrow
{
    return mask & 0x0FFFFFFFFFFFFFFF;
}


/// Get a bitmask corresponding to specified components.
/// 
/// Works at compile-time.
ulong ComponentFlags(ComponentTypes...)() @safe pure nothrow
{
    ulong result = 0;
    foreach(type; ComponentTypes)
    {
        assert(type.ComponentTypeID < 64, "Component type ID out of range");
        result |= 1UL << type.ComponentTypeID;
    }
    return result;
}


/// Type information about a component type.
struct ComponentTypeInfo
{
private:
    /// Type information about the source type the components are loaded from.
    /// 
    /// Ensures that a correct Source is passed to loadComponent.
    TypeInfo sourceType_;

public:
    /// ID of the component type (0 to 63).
    ulong id = ulong.max;

    /// Size of a single component of this type in bytes.
    size_t size;

    /// Name of the component type.
    string name = "";

    /// Type information about a component type field (data member).
    struct Field 
    {
        /// A function type to load the field.
        ///
        /// Params: ubyte[]: Component to load the field into, passed as a
        ///                  raw byte array.
        ///         void*:   Data source to load the field from.
        ///                  (e.g. a YAML node defining the component)
        ///                  Although a void pointer is used, the source must 
        ///                  match the type of the source used with the 
        ///                  construct! function that created this 
        ///                  ComponentTypeInfo.
        ///
        /// Returns: true if the field was successfully loaded, false otherwise.
        alias bool function(ubyte[], void*) pure nothrow LoadField;

        /// The function to load the field.
        LoadField loadField;
    }

    /// Type information about all fields (data members) in the component type.
    Field[] fields;

    /// Is this ComponentTypeInfo null (i.e. doesn't describe any type)?
    bool isNull() @safe pure nothrow const { return id == ulong.max; }


    /// Loads a component of this component type.
    ///
    /// Params:  componentData = Component to load into, as a raw bytes buffer.
    ///          source        = Source to load the component from (e.g. a YAML 
    ///                          node defining the component).
    bool loadComponent(Source)(ubyte[] componentData, ref Source source)
        @trusted pure nothrow const
    {
        assert(typeid(Source) is sourceType_, 
               "Source type used to construct a ComponentTypeInfo doesn't "
               "match the source type passed to its loadComponent method");
        
        // TODO we can implement modifying-entity-from-YAML easily;
        //      call loadField only for those fields that are present.
        //      The rest simply won't be overwritten.
        //      (note; Field struct must include the name of the field for this)
        assert(componentData.length == size, 
               "Size of component to load doesn't match its component type");
        foreach(ref f; fields)
        {
            if(!f.loadField(componentData, cast(void*)&source)) {return false;}
        }

        return true;
    }

    /// Construct a ComponentTypeInfo for specified component type.
    static ComponentTypeInfo construct(Source, Component)() @trusted
    {
        const fullName = Component.stringof;
        assert(fullName.endsWith("Component"), 
               "Component type name does not end with 'Component'");
        alias FieldNamesTuple!Component Fields;

        ComponentTypeInfo result;
        result.id   = Component.ComponentTypeID;
        result.size = Component.sizeof;
        result.name = fullName[0 .. fullName.length - "Component".length];
        result.fields.reserve(Fields.length);

        // This is a static foreach; the double brackets explicitly add a scope 
        // to separate the loadField functions generated for each field.
        foreach(name; Fields)
        {{
            static bool loadField(ubyte[] componentBuffer, void* sourceVoid)
            {
                Source* source = cast(Source*)sourceVoid;
                assert(componentBuffer.length == Component.sizeof, 
                       "Size of component buffer doesn't match its type");

                // TODO if a field has a default value, allow it to be 
                //      unspecified and set it to the default value here.
                if(source.isValue || !source.hasKey(name))
                {
                    writeln("Failed to load component '", Component.stringof,
                            "' : Field not specified: '", name, "'");
                    return false;
                }

                const value = (*source)[name];

                mixin(q{alias typeof(Component.%s) FieldType;}.format(name));

                if(!value.matchesType!FieldType)
                {
                    writeln("Failed to load component '", Component.stringof, 
                            "' : Field '", name, "' does not match expected "
                            "type: '", FieldType.stringof, "'");
                    return false;
                }

                mixin(q{
                (cast(Component*)componentBuffer.ptr).%s = value.as!FieldType;
                }.format(name));

                return true;
            }
            result.fields ~= Field(cast(Field.LoadField)&loadField);
        }}

        return result;
    }
}
