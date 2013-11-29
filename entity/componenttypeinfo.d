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
import tharsis.entity.resourcemanager;


/// A tuple of all builtin component types.
alias TypeTuple!(LifeComponent) BuiltinComponents;

/// Maximum possible number of builtin, mandatory component types.
package enum ushort maxBuiltinComponentTypes = 8;

/// Maximum possible number of component types in the 'defaults' package.
package enum ushort maxDefaultsComponentTypes = 24;

/// The number of component type IDs reserved for tharsis builtins and the 
/// defaults package.
///
/// Component type IDs of user-defined should use userComponentTypeID to avoid
/// collisions with builtin components.
enum ushort maxReservedComponentTypes =
    maxBuiltinComponentTypes + maxDefaultsComponentTypes;
 
/// Generate a component type ID for a user-defined component type.
///
/// Params: base = The base component type ID specified by the user. This must 
///                be different for every user-defined component type and must 
///                be less that the maxUserComponentTypes enum in the Policy 
///                parameter of the EntityManager; by default, this is 64.
template userComponentTypeID(ushort base)
{
    enum userComponentTypeID =
        maxBuiltinComponentTypes + maxDefaultsComponentTypes + base;
}

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

/// Determine if a component type is a MultiComponent type.
template isMultiComponent(Component) 
{
    enum isMultiComponent = 
        Unqual!Component.stringof.endsWith("MultiComponent");
}

/// Validate a component type at compile-time.
mixin template validateComponent(Component)
{
    alias std.traits.Unqual!Component BaseType;
    static assert(is(Component == struct),
                  "All component types must be structs");
    static assert(BaseType.stringof.endsWith("Component"), 
                  "Component type name does not end with 'Component'");
    static assert(__traits(hasMember, Component, "ComponentTypeID"),
                  "Component type without a ComponentTypeID: "
                  "add 'enum ComponentTypeID = <number>'");
    static assert(!isMultiComponent!Component ||
                  __traits(hasMember, Component, "maxComponentsPerEntity"),
                  "MultiComponent types must specify maximum component "
                  "count per entity: "
                  "add 'enum maxComponentsPerEntity = <number>'");
    static assert(!std.traits.hasElaborateDestructor!Component,
                  "Component type with an elaborate destructor: "
                  "Neither a component type nor any of its data members may "
                  "define a destructor.");
    //TODO annotation allowing the user to force a pointer/slice/class reference
    //     data member (e.g. to data allocated by a process).
    static assert(!std.traits.hasIndirections!Component,
                  "Component type with indirections (e.g. a pointer, slice "
                  "or class reference data member. Components are not allowed "
                  "to own any dynamically allocated memory; MultiComponents "
                  "can be used to emulate arrays. Pointers or slices to "
                  "externally allocated data, or class references may be "
                  "allowed in future with a special annotation, but this is "
                  "not implemented yet");
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

    /// Is this a MultiComponent type?
    bool isMulti = false;

    /// Name of the component type.
    string name = "";

    /// Name of the component when accessed in a Source (e.g. YAML).
    string sourceName = "";

    /// Minimum number of components to preallocate.
    uint minPrealloc = 0;

    /// Minimum number of components to preallocate per entity.
    double minPreallocPerEntity = 0;

    /// Type information about a component type field (data member).
    struct Field 
    {
        /// A function type to load the field.
        ///
        /// Params: ubyte[]:          Component to load the field into, passed 
        ///                           as a raw byte array.
        ///         void*:            Data source to load the field from.
        ///                           (e.g. a YAML node defining the component)
        ///                           Although a void pointer is used, the 
        ///                           source must match the type of the source
        ///                           used with the construct! function that 
        ///                           created this ComponentTypeInfo.
        ///         GetResourceHandle A delegate that, given (at runtime) a 
        ///                           resource type and descriptor, returns a
        ///                           raw resource handle. Used to initialize 
        ///                           fields that are resource handles.
        ///
        /// Returns: true if the field was successfully loaded, false otherwise.
        alias bool function(ubyte[], void*, GetResourceHandle) 
            nothrow LoadField;

        /// The function to load the field.
        LoadField loadField;
    }

    /// Type information about all fields (data members) in the component type.
    Field[] fields;

    /// Is this ComponentTypeInfo null (i.e. doesn't describe any type)?
    bool isNull() @safe pure nothrow const { return id == nullComponentTypeID; }


    /// Loads a component of this component type.
    ///
    /// Params:  componentData     = Component to load into, as a raw bytes 
    ///                              buffer.
    ///          source            = Source to load the component from (e.g. a 
    ///                              YAML node defining the component).
    ///          GetResourceHandle = A delegate that, given (at runtime) a 
    ///                              resource type and descriptor, returns a
    ///                              raw resource handle. Used to initialize 
    ///                              fields that are resource handles.
    bool loadComponent(Source)
                      (ubyte[] componentData, 
                       ref Source source,
                       GetResourceHandle getResourceHandle)
        @trusted nothrow const
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
        // Try to load all the fields. If we fail to load any single field,
        // loading fails.
        foreach(ref f; fields)
        {
            if(!f.loadField(componentData, 
                            cast(void*)&source,
                            getResourceHandle))
            {
                return false;
            }
        }

        return true;
    }

    /// Construct a ComponentTypeInfo for specified component type.
    static ComponentTypeInfo construct(Source, Component)() @trusted
    {
        mixin validateComponent!Component;
        alias FieldNamesTuple!Component Fields;

        enum fullName = Component.stringof;
        ComponentTypeInfo result;
        result.sourceType_ = typeid(Source);
        result.id          = Component.ComponentTypeID;
        result.size        = Component.sizeof;
        result.isMulti     = isMultiComponent!Component;
        result.name        = fullName[0 .. $ - "Component".length];
        result.sourceName  = result.name[0 .. 1].toLower ~ result.name[1 .. $];
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

        // Compile-time foreach.
        foreach(f; Fields)
        {
            result.fields ~= 
                Field(cast(Field.LoadField)&loadField!(Source, Component, f));
        }

        return result;
    }

private:
    /// Loads a field of a Component from a Source.
    ///
    /// Params: Source            = The Source type to load from 
    ///                             (e.g. YAMLSource).
    ///         Component         = Component type we're loading.
    ///         fieldName         = Name of the data member of Component to
    ///                             load.
    ///         componentBuffer   = The component we're loading as raw bytes.
    ///         sourceVoid        = A void pointer to the Source we're loading
    ///                             from.
    ///         getResourceHandle = A function that will get a raw handle to a 
    ///                             resource when passed resource type and 
    ///                             descriptor. Used to initialize component 
    ///                             fields that are resource handles.
    static bool loadField(Source, Component, string fieldName)
                         (ubyte[] componentBuffer, void* sourceVoid, 
                          GetResourceHandle getResourceHandle)
    {
        assert(componentBuffer.length == Component.sizeof, 
               "Size of component buffer doesn't match its type");

        // TODO if a field has an explicit default value, allow it to be 
        //      unspecified and set it to the default value here.

        // The component is stored in a mapping; the field is stored in a 
        // Source that is one of the values in that mapping.
        Source fieldSource;
        Source* source = cast(Source*)sourceVoid;
        if(!source.getMappingValue(fieldName, fieldSource))
        {
            writefln("Failed to load component '%s': Couldn't find field: '%s'",
                     Component.stringof, fieldName);
            return false;
        }
        mixin(q{
        auto fieldPtr = &((cast(Component*)componentBuffer.ptr).%s);
        }.format(fieldName));
        alias typeof(*fieldPtr) FieldType;

        // If a component property is a resource handle, the Source contains a
        // resource descriptor. We need to load the descriptor and then get the
        // handle by getResourceHandle(), which will create a resource with the
        // correct resource manager and return a handle to it.
        static if(isResourceHandle!(Component, fieldName))
        {
            alias Resource   = FieldType.Resource;
            alias Descriptor = Resource.Descriptor;
            alias Handle     = ResourceHandle!Resource;

            // Load the descriptor of the resource.
            Descriptor desc;
            if(!Descriptor.load(fieldSource, desc))
            {
                writefln("Failed to load component '%s' : Field '%s' does not "
                         "match expected type: '%s'",
                         Component.stringof, fieldName, Descriptor.stringof);
                return false;
            }

            // Initialize the field which is a handle to the resource.
            *fieldPtr = Handle(getResourceHandle(typeid(Resource), &desc));
        }
        // By default, properties are stored in the Source directly as values.
        else if(!fieldSource.readTo(*fieldPtr))
        {
            writefln("Failed to load component '%s' : Field '%s' does not "
                     "match expected type: '%s'",
                     Component.stringof, fieldName, FieldType.stringof);
            return false;
        }

        return true;
    }
}

private:

/// Is Component.field a resource handle?
///
/// Params: Component = A Component type.
///         field     = Name of a data member of Component.
///
/// Returns: true if the field data member of Component is a resource handle,
///          false otherwise.
bool isResourceHandle(Component, string field)()
{
    mixin(q{
    alias fieldType = Unqual!(typeof(Component.%s));
    }.format(field));

    enum fieldTypeString = fieldType.stringof;
    return fieldTypeString.startsWith("ResourceHandle!");
}
