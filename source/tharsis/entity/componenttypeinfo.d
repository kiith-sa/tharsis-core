//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Type information about a component type.
module tharsis.entity.componenttypeinfo;


import std.algorithm;
import std.array;
import std.exception : assumeWontThrow;
import std.stdio;
import std.string;
import std.traits;
import std.typetuple;

import tharsis.util.noncopyable;
import tharsis.util.traits;
import tharsis.util.typetuple;
import tharsis.entity.lifecomponent;
import tharsis.entity.resourcemanager;


/// A tuple of all builtin component types.
alias TypeTuple!(LifeComponent) BuiltinComponents;

/// Maximum possible number of builtin, mandatory component types.
package enum ushort maxBuiltinComponentTypes = 8;

/// Maximum possible number of component types in the 'defaults' package.
package enum ushort maxDefaultsComponentTypes = 24;

/** Number of component type IDs reserved for Tharsis builtins and the defaults package.
 *
 * Component type IDs of user-defined components should use userComponentTypeID to avoid\
 * collisions with builtin components.
 */
enum ushort maxReservedComponentTypes = maxBuiltinComponentTypes + maxDefaultsComponentTypes;

/** Generate a component type ID for a user-defined component type.
 *
 * Params: base = Base component type ID specified by user. Must be different for every
 *                user-defined component type, must be less than the maxUserComponentTypes
 *                enum in the Policy parameter of EntityManager; by default, this is 64.
 */
enum userComponentTypeID(ushort base) = maxBuiltinComponentTypes +
                                        maxDefaultsComponentTypes + base;

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

/** Get the maximum possible components of this type at entity may have.
 *
 * Used mainly by MultiComponents. For normal Components this is a minimum number of free
 * preallocated components.
 */
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
enum isMultiComponent(Component) = Unqual!Component.stringof.endsWith("MultiComponent");

/// Validate a component type at compile-time.
mixin template validateComponent(Component)
{
    // Mixins only see the imports of the module where they are mixed in; so
    // we also need to mix in the required imports.
    import std.algorithm;

    alias std.traits.Unqual!Component BaseType;
    static assert(is(Component == struct), "All component types must be structs");
    static assert(BaseType.stringof.endsWith("Component"),
                  "Component type name does not end with 'Component'");
    static assert(__traits(hasMember, Component, "ComponentTypeID"),
                  "Component type without a ComponentTypeID: add 'enum ComponentTypeID "
                  "= <number>'");
    static assert(!isMultiComponent!Component ||
                  __traits(hasMember, Component, "maxComponentsPerEntity"),
                  "MultiComponent types must specify max component count per entity: add "
                  "'enum maxComponentsPerEntity = <number>'");
    static assert(!std.traits.hasElaborateDestructor!Component,
                  "Component type with an elaborate destructor: Neither a component type "
                  "nor any of its data members may define a destructor.");
    //TODO annotation allowing the user to force a pointer/slice/class reference
    //     data member (e.g. to data allocated by a process).
    static assert(!std.traits.hasIndirections!Component,
                  "Component type with indirections (e.g. pointer, slice or class field) "
                  "Components may not own dynamically allocated memory; MultiComponents "
                  "can be used to emulate arrays. Pointers or slices to externally "
                  "allocated data, or class references may be allowed in future with a "
                  "special annotation, but this is not implemented yet");
}

/** Used as an user-defined attribute for component properties to override the name of the
 * property in the Source it's loaded from (e.g. YAML).
 */
struct PropertyName
{
    /// The name of the property in a Source such as YAML.
    string name;
}

/** Stores a component of any component type as raw data.
 *
 * This is a dumb struct. The code that constructs a RawComponent must make sure the type
 * and data used actually makes sense (also e.g. that data size matches the type).
 */
struct RawComponent
{
private:
    /// Type ID of the component.
    ushort typeID_ = nullComponentTypeID;
    /** Slice containing untyped raw data.
     *
     * The slice should point to memory owned externally, e.g. to memory of an EntityPrototype.
     */
    ubyte[] componentData_;

public:
    @safe pure nothrow @nogc:

    /// Get an ID specifying type of the component
    ushort typeID() const { return typeID_; }

    /// Get the component as raw data.
    inout(ubyte)[] componentData() inout { return componentData_; }

    /** Read the component as a concrete component type.
     *
     * Params:
     *
     * Component = Component type to read the component as. Must be the actual type of the
     *             RawComponent (its ComponentTypeID must match typeID of this RawComponent).
     */
    ref Component as(Component)() @trusted pure nothrow @nogc 
    {
        assert(typeID_ == Component.ComponentTypeID,
               "Trying to read a RawComponent as the incorrect concrete component type");
        return *cast(Component*)componentData_.ptr;
    }

    /** Is this a null component?
     *
     * Some functions may return a null component on error or if no component was found.
     */
    bool isNull() const { return typeID_ == nullComponentTypeID; }
}

/**
 * An immutable equivalent of RawComponent.
 *
 * Must be a separate type to avoid construction issues.
 *
 * See_Also: RawComponent
 */
struct ImmutableRawComponent
{
public:
    /// The RawComponent itself.
    immutable(RawComponent) self_;
    alias self_ this;

    /// Construct an ImmutableRawComponent with specified type and data.
    this(ushort typeID, immutable(ubyte)[] componentData) @safe pure nothrow @nogc
    {
        self_ = immutable(RawComponent)(typeID, componentData);
    }
}


/// Type information about a component type property (data member).
struct ComponentPropertyInfo
{
    /// No copying; copies in separate threads may unexpectedly access shared resources.
    mixin(NonCopyable);

private:
    /** A function type to load the property from a source (e.g. YAML).
     *
     * Params:
     *
     * ubyte[]:          Component with the property to load, as a raw byte array.
     * void*:            Source to load the property from, e.g. a YAML node defining the
     *                   component. Although we use a void pointer, the source must match
     *                   the type of the source used with the construct() function that
     *                   created this ComponentPropertyInfo.
     * GetResourceHandle A deleg that, given resource type ID and descriptor, returns a
     *                   raw resource handle. Used to init properties that are resource
     *                   handles. Always passed but not every property will use this.
     * string            A string to write any loading errors to. If there are no 
     *                   errors, this is not touched.
     *
     * Returns: true if the property was successfully loaded, false otherwise.
     */
    alias LoadProperty = bool function(ubyte[], void*, GetResourceHandle, ref string) nothrow;

    /* A function type to add the value of this property in right to the value in left.
     *
     * See_Also: addRightToLeft
     */
    alias AddRightToLeft = void function(ref RawComponent left, ref const(RawComponent) right)
                           @safe pure nothrow;


    /* The function to load the property.
     *
     * See_Also: LoadProperty
     */
    LoadProperty loadProperty;

    // See_Also: customAttributes
    string[8] customAttributes_;

    /* A function that adds the value of this property in one component to the value of
     * this property in another component.
     *
     * See_Also: addRightToLeft
     */
    AddRightToLeft addRightToLeft_;

public:
    /** Custom attributes of the property.
     *
     * For example, @("relative") .
     * Processes can get propeties with a specific custom attribute using the properties()
     * method of ComponentTypeInfo. This is used e.g. in
     * tharsis.defaults.processes.SpawnerProcess to implement relative properties where a
     * property of a spawned entity is affected by the same property of the spawner.
     */
    const(string)[] customAttributes() @safe pure nothrow const @nogc
    {
        return customAttributes_[];
    }

    /** Add the value of this property in the right component to this property in the left
     * component.
     *
     * If "property" is the property (data member) represented by this ComponentPropertyInfo,
     * this is an equivalent of "left.property += right.property". Both components must be
     * of the component type that has this property.
     *
     * May only be called for properties where "left.property += right.property" compiles.
     * Used to implement relative properties to e.g. spawn new entities at relative positions.
     *
     * Params: left  = The component to add to. Must be a component of the component type
     *                 that has this property.
     *         right = The component to get the value to add from. Must be a component of
     *                 the component type that has this property.
     */
    void addRightToLeft(ref RawComponent left, ref const(RawComponent) right)
        @safe pure nothrow const
    {
        addRightToLeft_(left, right);
    }

private:
    /** Construct ComponentPropertyInfo describing a property (field) of a component type.
     *
     * Params:  Source    = Source type we're loading components from, e.g. YAMLSource.
     *          Component = Component type the property belongs to.
     *          fieldName = Name of the field (property) in the component type. E.g. for
     *                      PhysicsComponent.position this would be "position".
     */
    this(Source, Component, string fieldName)() @safe pure nothrow @nogc
    {
        auto loadPropDg = &implementLoadProperty!(Source, Component, fieldName);
        // The cast adds the nothrow attribute (implementLoadProperty does not throw
        // even though we can't mark it nothrow as of DMD 2.065).

        loadProperty    = loadPropDg;
        addRightToLeft_ = &implementAddRightToLeft!(Component, fieldName);

        // Get user defined attributes of the property.
        mixin(q{
        alias attribs = TypeTuple!(__traits(getAttributes, Component.%s));
        }.format(fieldName));


        // All string user defined attributes are stored in customAttributes_.
        enum isString(alias attrib) = is(typeof(attrib) == string);
        foreach(i, attrib; Filter!(isString, attribs))
        {
            enum maxAttribs = customAttributes_.length;
            static assert(i < maxAttribs,
                          "%s.%s has too many attributes; at most %s are supported"
                          .format(Component.stringof, fieldName, maxAttribs));
            customAttributes_[i] = attrib;
        }
    }

    /** Get the name of a property used in a Source such as YAML.
     *
     * Property name in a Source is by default the name of the property in the component
     * struct, but it can be overridden by a PropertyName attribute. This is useful e.g.
     * if a property name would collide with a D keyword.
     */
    static string fieldNameSource(Component, string fieldNameInternal)()
    {
        string result;
        mixin(q{
        alias fieldAttribs = TypeTuple!(__traits(getAttributes, Component.%s));
        }.format(fieldNameInternal));

        // Find the PropertyName attribute, if any. More than one is illegal.
        enum isPropertyName(alias attrib) = is(typeof(attrib) == PropertyName);
        foreach(attrib; Filter!(isPropertyName, fieldAttribs))
        {
            assert(result is null,
                   "More than one PropertyName attribute on a component property");
            result = attrib.name;
        }

        return result is null ? fieldNameInternal : result;
    }

    /** This template generates an implementation of addRightToLeft for property
     * fieldNameInternal of component type Component.
     *
     * When a component type is registered, this template is instantiated for all its
     * properties to implement addRightToLeft for every one of them.
     *
     * Params: Component         = The component type to which the property belongs.
     *         fieldNameInternal = The name of the property (field) in the component 
     *                             struct (as opposed to its name in a Source such as YAML).
     *
     * See_Also: addRightToLeft
     */
    static void implementAddRightToLeft
        (Component, string fieldNameInternal)
        (ref RawComponent left, ref const(RawComponent) right) @trusted pure nothrow
    {
        assert(left.typeID == right.typeID && left.typeID == Component.ComponentTypeID,
               "Components of different types passed to addRightToLeft");
        // Cast the pointers to the component type.
        auto leftTyped  = cast(Component*)left.componentData.ptr;
        auto rightTyped = cast(const(Component)*)right.componentData.ptr;

        mixin(q{
        static if(!__traits(compiles, leftTyped.%1$s += rightTyped.%1$s))
        {
            assert(false, "%2$s.%1$s does not support addition");
        }
        else
        {
            leftTyped.%1$s += rightTyped.%1$s;
        }
        }.format(fieldNameInternal, Component.stringof));
    }


    /** This template generates an implementation of loadProperty loading property
     * fieldNameInternal of component type Component from source type Source.
     *
     * When registering a component type, this template is instantiated for its properties
     * to implement loadProperty for every one of them.
     *
     * Params: Source            = The Source type to load from (e.g. YAMLSource).
     *         Component         = Component type we're loading.
     *         fieldNameInternal = Name of the property in the Component struct to load
     *                             (may differ from the name of the same property in
     *                             component source).
     *
     * See_Also: LoadProperty
     */
    static bool implementLoadProperty
        (Source, Component, string fieldNameInternal)
        (ubyte[] componentRaw, void* sourceRaw, GetResourceHandle getHandle,
         ref string errorLog) nothrow
    {
        assert(componentRaw.length == Component.sizeof,
               "Size of component buffer doesn't match its type");

        enum string compName = Component.stringof;

        // The component is stored in a mapping; the property in a Source that is one of
        // the values in that mapping.
        Source fieldSource;
        Source* source = cast(Source*)sourceRaw;
        import std.exception;
        if(!source.isMapping)
        {
            errorLog ~= "'%s' failed to load: Component source is not a mapping\n\n"
                        .format(compName).assumeWontThrow;
            return false;
        }

        // Is this property a resource handle?
        enum isResource = isResourceHandle!(Component, fieldNameInternal);

        // Pointer to the field in the component.
        mixin(q{
        auto fieldPtr = &((cast(Component*)componentRaw.ptr).%s);
        }.format(fieldNameInternal));

        alias typeof(*fieldPtr) FieldType;

        // Property name used when loading from the Source. May be different from the
        // name of the Component's property.
        enum string fieldName = fieldNameSource!(Component, fieldNameInternal);
        if(!source.getMappingValue(fieldName, fieldSource))
        {
            static if(isResource)
            {
                errorLog ~= "'%s' falied to load: Property '%s' not found\n\n"
                            .format(compName, fieldName).assumeWontThrow;
                return false;
            }
            // If the property is not found in the Source, and the property is not a
            // resource handle, default-initialize it.
            else
            {
                import tharsis.util.debughacks;
                mixin(q{
                *fieldPtr = Component.init.%s;
                }.format(fieldNameInternal));
                return true;
            }
        }

        enum failedToLoad = "'%s' failed to load: Property '%s'".format(compName, fieldName)
                          ~ " does not have expected type '%s'\n\n";
        // If a property is a resource handle, source contains a resource descriptor. We
        // load the descriptor and init the handle by getHandle(), which will create a
        // resource with the correct resource manager and return a handle to it.
        static if(isResource)
        {
            alias Resource   = FieldType.Resource;
            alias Descriptor = Resource.Descriptor;
            alias Handle     = ResourceHandle!Resource;

            // Load the descriptor of the resource.
            Descriptor desc;
            if(!Descriptor.load(fieldSource, desc))
            {
                errorLog ~= failedToLoad.format(Descriptor.stringof).assumeWontThrow;
                return false;
            }

            // Initialize the property which is a handle to the resource.
            *fieldPtr = Handle(getHandle(typeid(Resource), &desc));
        }
        // By default, properties are stored in the Source directly as values.
        else if(!fieldSource.readTo(*fieldPtr))
        {
            errorLog ~= failedToLoad.format(FieldType.stringof).assumeWontThrow;
            return false;
        }

        return true;
    }
}

/// Type information about a component type.
struct ComponentTypeInfo
{
    /// No copying; copies in separate threads may unexpectedly access shared resources.
    mixin(NonCopyable);

public:
    /// ID of the component type.
    ushort id = nullComponentTypeID;

    /// Size of a single component of this type in bytes.
    size_t size;

    /** Maximum possible components of this type in a single entity.
     *
     * Used mainly by MultiComponents. Used by EntitySystem to ensure there are always
     * enough components preallocated for the next entity to process.
     */
    size_t maxPerEntity = 1;

    /// Is this a MultiComponent type?
    bool isMulti = false;

    /** Name of the component type.
     *
     * This is the component struct name without the 'Component' suffix. E.g. for
     * "PhysicsComponent" this would be "Physics"
     */
    string name = "";

    /** Name of the component when accessed in a Source (e.g. YAML).
     *
     * Usually this is equal to name with the first character forced to lowercase.
     */
    string sourceName = "";

    /// Minimum number of components to preallocate between game updates.
    uint minPrealloc = 0;

    /// Minimum number of components to preallocate per entity between game updates.
    double minPreallocPerEntity = 0;

private:
    /** Type info of the Source (e.g. YAML) type the components are loaded from.
     *
     * Ensures that a correct Source is passed to loadComponent.
     */
    TypeInfo sourceType_;

    /// Information about all properties (data members) in the component type.
    ComponentPropertyInfo[] properties_;

public:
    /** A range that iterates over type info of properties (aka fields or data members) of
     * a Component type.
     *
     * The range element type is ComponentPropertyInfo.
     */
    //
    // Currently this works as a filter that iterates only over entities with
    // a specified attribute.
    struct ComponentPropertyRange
    {
        /// No copying; copies in separate threads may unexpectedly access shared resources.
        mixin(NonCopyable);

    private:
        /// A slice of all properties of the component type.
        const(ComponentPropertyInfo)[] properties_;

        /** We only iterate over properties that have a this user-defined attribute.
         *
         * E.g. if filterAttribute_ is "relative", the range will iterate over
         * '@("relative") float x' but not over 'float x'
         */
        string filterAttribute_;

    public:
        /// Get the current element of the range.
        ref const(ComponentPropertyInfo) front() @safe pure nothrow const @nogc
        {
            assert(!empty, "Can't get front of an empty range");
            return properties_.front;
        }

        /// Remove the current element of the range, moving to the next.
        void popFront() @safe pure nothrow
        {
            assert(!empty, "Can't pop front of an empty range");
            properties_.popFront();
            skipToNextMatch();
        }

        /// Is the range empty? (No more elements)
        bool empty() @safe pure nothrow const @nogc { return properties_.empty(); }

    private:
        /* Construct a ComponentProperty iterating over properties with specified attrib.
         *
         * Params: properties = A slice of all properties of the component type.
         *         attribute  = Only properties with this user-defined attribute will be
         *                      iterated by the range.
         */
        this(const(ComponentPropertyInfo)[] properties, string attribute)
            @safe pure nothrow
        {
            properties_ = properties;
            filterAttribute_ = attribute;
            skipToNextMatch();
        }

        /* Skip to next property with user-defined attribute filterAttribute_ or to the
         * end of the range.
         */
        void skipToNextMatch() @safe pure nothrow
        {
            while(!properties_.empty &&
                  !properties_.front.customAttributes.canFind(filterAttribute_))
            {
                properties_.popFront();
            }
        }
    }

   /** Get a range of properties of a component type with specified user-defined attribute.
    *
    * Example:
    * --------------------
    * struct PhysicsComponent
    * {
    *     enum ushort ComponentTypeID = userComponentTypeID!2;
    *
    *     float mass;
    *     @("relative") float x;
    *     @("relative") float y;
    *     @("relative") float z;
    * }
    *
    * // ComponentTypeInfo info; // type info about PhysicsComponent
    *
    * foreach(ref propertyInfo; info.properties("relative"))
    * {
    *     // Will iterate over ComponentPropertyInfo for 'float x', 'float y' and
    *     // 'float z'
    * }
    *
    * --------------------
    */
    ComponentPropertyRange properties(string attribute)()
        @safe pure nothrow const
    {
        //TODO Maybe build a range storing an array of properties with specified attrib,
        //     and cache the range between calls. Faster, but more memory than
        //     ComponentPropertyRange, which filters on-the-fly. To avoid thread issues we
        //     can use a static array (static is per-thread and this is a template func so
        //     there'd be a separate array per attrib - but we'd need separate entries per
        //     component type. We may even build all these arrays at startup as we know
        //     which attribs are being used at compile-time).
        return ComponentPropertyRange(properties_, attribute);
    }

    /// Is this ComponentTypeInfo null (i.e. doesn't describe any type)?
    bool isNull() @safe pure nothrow const @nogc { return id == nullComponentTypeID; }

    import tharsis.entity.entitymanager;
    /** Load a component of this component type.
     *
     * Params:
     *
     * Source        = Type of Source (e.g. YAML) to load from. Must be the same Source
     *                 type that was used when the type info was initialized (i.e. the
     *                 Source parameter of ComponentTypeManager).
     * componentData = Component to load into, as a byte array.
     * source        = Source to load the component from (e.g. a component stored as YAML).
     * entityManager = Entity manager (needed to get access to resource management - to
     *                 initialize any resource handles in the component).
     * errorLog      = A string to write any loading errors to. If there are no errors,
     *                 this is not touched.
     */
    bool loadComponent(Source, Policy)(ubyte[] componentData, ref Source source,
                                       EntityManager!Policy entityManager, ref string errorLog)
        @trusted nothrow const
    {
        assert(typeid(Source) is sourceType_,
               "Source type used to construct a ComponentTypeInfo doesn't match the "
               "source type passed to its loadComponent method");

        assert(componentData.length == size,
               "Size of component to load doesn't match its component type");
        auto getHandle = &entityManager.rawResourceHandle;
        // Try to load all the properties. If we fail to load any single property,
        // loading fails.
        foreach(ref p; properties_)
        {
            if(!p.loadProperty(componentData, cast(void*)&source, getHandle, errorLog))
            {
                return false;
            }
        }

        return true;
    }

private:
    /** Construct component type information for specified component type.
     *
     * Params:  Source    = Source the components will be loaded from (e.g. YAML).
     *          Component = Component type to generate info about.
     */
    this(Source, Component)() @safe pure nothrow
    {
        mixin validateComponent!Component;
        alias FieldNamesTuple!Component Fields;

        enum fullName = Component.stringof;
        sourceType_ = typeid(Source);
        id          = Component.ComponentTypeID;
        size        = Component.sizeof;
        isMulti     = isMultiComponent!Component;
        name        = fullName[0 .. $ - "Component".length];
        sourceName  = name[0 .. 1].toLower.assumeWontThrow ~ name[1 .. $];

        static if(hasMember!(Component, "minPrealloc"))
        {
            minPrealloc = Component.minPrealloc;
        }
        static if(hasMember!(Component, "minPreallocPerEntity"))
        {
            minPreallocPerEntity = Component.minPreallocPerEntity;
        }
        maxPerEntity = maxComponentsPerEntity!Component();

        // Property information contains a generated loadProperty function that can load
        // that property from a Source.
        properties_.length = Fields.length;
        // Compile-time foreach.
        foreach(i, fieldName; Fields)
        {
            properties_[i].__ctor!(Source, Component, fieldName)();
        }
    }
}

private:

/** Is Component.property a resource handle?
 *
 * Params: Component = A Component type.
 *         property  = Name of a property (data member) of Component.
 *
 * Returns: true if the property of Component with specified name is a resource handle,
 *          false otherwise.
 */
bool isResourceHandle(Component, string property)()
{
    mixin(q{
    alias fieldType = Unqual!(typeof(Component.%s));
    }.format(property));

    enum fieldTypeString = fieldType.stringof;
    return fieldTypeString.startsWith("ResourceHandle!");
}
