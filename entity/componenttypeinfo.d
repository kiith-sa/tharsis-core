//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Type information about a component type.
module tharsis.entity.componenttypeinfo;


import std.algorithm;
import std.array;
import std.stdio;
import std.string;
import std.traits;
import std.typetuple;

import tharsis.util.traits;


import tharsis.entity.lifecomponent;
/// A tuple of all builtin component types.
alias TypeTuple!(LifeComponent) BuiltinComponents;

/// Maximum possible number of builtin, mandatory component types.
///
/// Component type IDs of user-defined components should add to this number to 
/// avoid collisions with builtin components.
enum ushort maxBuiltinComponentTypes = 8;

/// A 'null' component type ID, e.g. to specify a unused component buffer.
enum ushort nullComponentTypeID = 0;

/// Get a sorted array of IDs of specified component types.
ushort[] componentIDs(ComponentTypes...)() @trusted
{
    ushort[] ids;
    foreach(type; ComponentTypes) { ids ~= type.ComponentTypeID; }
    ids.sort();
    return ids;
}

/// Get the maximum possible components of this type at entity may have.
///
/// Used mainly by MultiComponents. For normal Components this is a minimum 
/// number of free preallocated components.
auto maxComponentsPerEntity(ComponentType)() @safe pure nothrow
{
    static if(__traits(hasMember, ComponentType, "maxComponentsPerEntity"))
    {
        return ComponentType.maxComponentsPerEntity;
    }
    else 
    {
        return 1;
    }
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
    /// ID of the component type.
    ushort id = nullComponentTypeID;

    /// Size of a single component of this type in bytes.
    size_t size;

    /// Maximum possible components of this type at entity may have.
    ///
    /// Used mainly by MultiComponents. For normal Components this is a minimum 
    /// number of free preallocated components.
    size_t maxPerEntity = 1;

    /// Name of the component type.
    string name = "";

    /// Minimum number of components to preallocate.
    uint minPrealloc = 0;

    /// Minimum number of components to preallocate per entity.
    double minPreallocPerEntity = 0;

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
    bool isNull() @safe pure nothrow const { return id == nullComponentTypeID; }


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

        static if(hasMember!(Component, "minPrealloc"))
        {
            result.minPrealloc = Component.minPrealloc;
        }
        static if(hasMember!(Component, "minPreallocPerEntity"))
        {
            result.minPreallocPerEntity = Component.minPreallocPerEntity;
        }
        result.maxPerEntity = maxComponentsPerEntity!Component();

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
                Source value;
                if(!source.getMappingValue(name, value))
                {
                    writeln("Failed to load component '", Component.stringof,
                            "' : Could not find field: '", name, "'");
                    return false;
                }

                mixin(q{alias typeof(Component.%s) FieldType;}.format(name));

                mixin(q{
                FieldType* field = &((cast(Component*)componentBuffer.ptr).%s);
                }.format(name));

                if(!value.readTo(*field))
                {
                    writeln("Failed to load component '", Component.stringof, 
                            "' : Field '", name, "' does not match expected "
                            "type: '", FieldType.stringof, "'");
                    return false;
                }

                return true;
            }
            result.fields ~= Field(cast(Field.LoadField)&loadField);
        }}

        return result;
    }
}
