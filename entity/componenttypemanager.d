//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Component type registering, type information management and loading.
module tharsis.entity.componenttypemanager;


import std.algorithm;
import std.string;
import std.typecons;
import std.typetuple;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.entitypolicy;


/// Base class for component type managers.
///
/// See_Also: ComponentTypeManager.
class AbstractComponentTypeManager(Policy)
{
    mixin validateEntityPolicy!Policy;

private:
    /// Is this manager locked (i.e. no more types may be registered)?
    bool locked_;

protected:
    /// Type information for all registered component types.
    ///
    /// Every index corresponds to a component type ID.
    /// If there is no registered component type with a particular ID, the
    /// ComponentTypeInfo at its corresponding index is null.
    ComponentTypeInfo[maxComponentTypes!Policy] componentTypeInfo_;

public:
    /// Lock the component type manager.
    ///
    /// After this is called, no more types can be registered. Must be called before
    /// passing this manager to an EntityManager.
    final void lock() @safe pure nothrow
    {
        assert(!locked_, "Trying to lock a component type manager twice.");
        locked_ = true;
    }

    /// Is this manager locked?
    final @property bool locked() @safe const pure nothrow {return locked_;}

    /// Are all specified component types registered?
    final bool areTypesRegistered(Types ...)() @safe nothrow const
    {
        foreach(Type; Types)
        {
            const id = Type.ComponentTypeID;
            bool isRegistered = false;
            foreach(ref type; componentTypeInfo_) if(!type.isNull && type.id == id)
            {
                isRegistered = true;
            }
            if(!isRegistered) { return false; }
        }

        return true;
    }

    /// Get the maximum size of all components in any single entity in bytes.
    ///
    /// Useful when preallocating memory for entity prototypes.
    ///
    /// Can only be called after this manager is locked.
    final size_t maxEntityBytes() @safe pure nothrow const
    {
        assert(locked, "Can't determine max bytes per entity before locking "
                       "ComponentTypeManager");
        size_t result;
        foreach(ref componentType; componentTypeInfo_)
        {
            result += componentType.isNull
                    ? 0 : componentType.size * componentType.maxPerEntity;
        }
        return result;
    }

    /// Get the maximum number of components (of all types) in a single entity.
    ///
    /// Can only be called after this manager is locked.
    final size_t maxEntityComponents() @safe pure nothrow const
    {
        assert(locked, "Can't determine max components per entity before locking "
                       "ComponentTypeManager");
        size_t result;
        foreach(ref componentType; componentTypeInfo_)
        {
            result += componentType.isNull ? 0 : componentType.maxPerEntity;
        }
        return result;
    }

    /// Get type information about all registered components.
    ///
    /// Returns a slice; component type IDs are indices to this slice. Some elements may
    /// be null (determine this using ComponentTypeInfo.isNull).
    ///
    /// Can only be called after this manager is locked.
    ref const(ComponentTypeInfo[maxComponentTypes!Policy]) componentTypeInfo()
        @safe pure nothrow const
    {
        assert(locked, "Can't access component type info before locking "
                       "ComponentTypeManager");
        return componentTypeInfo_;
    }
}

/// Maximum size of an instance of a Source type in bytes.
enum maxSourceBytes = 512;


/// Manages component type information and loading.
///
/// Before creating an EntityManager, all component types must be registered with a
/// ComponentTypeManager that will be passed to the constructor of an EntityManager.
///
/// Params: Source = A struct type to read components from. This may be for example a
///                  wrapped YAML or XML node, or an INI section. See below.
///         Policy = Specifies compile-time parameters such as the maximum number of
///                  component types. See tharsis.entity.entitypolicy.d for the default
///                  Policy type.
///
/// Example:
/// --------------------
/// // struct SomeSource
/// // SomeSource.Loader loader
/// // AComponent, BComponent, CComponent
///
/// // Construct the component type manager
/// auto componentTypes = new ComponentTypeManager!SomeSource(loader);
/// // Register a component type
/// componentTypes.registerComponentTypes!AComponent();
/// // Register 2 component types at the same time
/// componentTypes.registerComponentTypes!(BComponent, CComponent();
/// // Lock to disallow further component type changes.
/// // Must be called before passing to EntityManager.
/// componentTypes.lock();
/// // Construct the entity manager.
/// auto entityManager = new EntityManager(componentTypes);
/// --------------------
///
/// Limitations of a Source struct:
///
/// sizeof of a Source struct can be at most maxSourceBytes (currently set to 512).
/// A Source struct must be copyable; if it includes nested data (such as JSON/XML/YAML
/// subnodes), copying a Source must either also copy this nested data or share it by
/// using e.g. reference counting or garbage collector managed storage.
///
/// Skeleton of a Source struct:
/// --------------------
/// // Note that some manual casting might be required to ensure that methods of
/// // a Source struct have required attributes (such as pure, nothrow, etc.).
/// //
/// // This can be done safely by ensuring that the method indeed obeys the attribute
/// // (e.g. ensuring that all exceptions are caught) and manually casting any functions
/// // that don't obey the attribute.
/// //
/// // For example:
/// //
/// // (cast(void delegate(int, int) @safe nothrow)&methodThatDoesntThrow)()
/// struct Source
/// {
/// public:
///     /// Handles loading of Sources.
///     struct Loader
///     {
///     public:
///         /// Load a Source with specified name (e.g. entity file name).
///         ///
///         ///
///         /// Params: name      = Name to identify the source by (e.g. a file name).
///         ///         logErrors = If true, errors generated during the use of
///         ///                     the Source (such as loading errors, conversion
///         ///                     errors etc.) should be logged, accessible through
///         ///                     the errorLog() method of Source.
///         ///
///         /// There is no requirement to load from actual files; this may be
///         /// implemented by loading from some archive file or from memory.
///         TestSource loadSource(string name, bool logErrors) @safe nothrow
///         {
///             assert(false);
///         }
///     }
///
///     /// If true, the Source is 'null' and doesn't store anything.
///     ///
///     /// A null Source may be returned when loading a Source fails, e.g. from 
///     /// Loader.loadSource().
///     bool isNull() @safe nothrow const
///     {
///         assert(false);
///     }
///
///     /// If logging is enabled, returns errors logged during construction and use
///     /// of this Source. Otherwise returns a warning message.
///     string errorLog() @safe pure nothrow const
///     {
///         assert(false);
///     }
///
///     /// Read a value of type T to target.
///     ///
///     /// Returns: true if the value was successfully read.
///     ///          false if the Source isn't convertible to specified type.
///     bool readTo(T)(out T target) @safe nothrow
///     {
///         assert(false);
///     }
///
///     /// Get a nested Source from a 'sequence' Source.
///     ///
///     /// (Get a value from a Source that represents an array of Sources)
///     ///
///     /// Params:  index  = Index of the Source to get in the sequence.
///     ///          target = Target to read the Source to.
///     ///
///     /// Returns: true on success, false on failure. (e.g. if this Source is
///     ///          a not a sequence, or the index is out of range).
///     bool getSequenceValue(size_t index, out TestSource target) @safe nothrow
///     {
///         assert(false);
///     }
///
///     /// Get a nested Source from a 'mapping' Source.
///     ///
///     /// (Get a value from a Source that maps strings to Sources)
///     ///
///     /// Params:  key    = Key identifying the nested Source.
///     ///          target = Target to read the nested Source to.
///     ///
///     /// Returns: true on success, false on failure. (e.g. if this Source is
///     ///          a not a mapping, or if there is no such key.)
///     bool getMappingValue(string key, out TestSource target) @safe nothrow
///     {
///         assert(false);
///     }
/// }
/// --------------------
// TODO once default values are supported, mention how that is handled here.
/// Format of components in a Source struct:
///
/// A Source to load an entity from must be a mapping where keys are lower-case names of
/// component types without the "Component" suffix. The values corresponding to these
/// keys must be mappings containing the component's properties.
///
/// E.g. to load an int property "awesomeness" of an ExampleComponent, Tharsis will use
/// the Source API roughly in the following way:
///
/// --------------------
/// bool getAwesomeness(ref const(Source) components, out int awesomeness)
/// {
///     if(components.isNull())
///     {
///         writeln("components is null");
///         return false;
///     }
///     Source exampleComponent;
///     if(!component.getMappingValue("example", exampleComponent))
///     {
///         writeln("could not find ExampleComponent in components");
///         return false;
///     }
///     Source awesomenessSource;
///     if(!exampleComponent.getMappingValue("awesomeness", awesomenessSource))
///     {
///         writeln("could not find awesomeness in ExampleComponent");
///         return false;
///     }
///     if(!awesomenessSource.readTo(awesomeness))
///     {
///         writeln("awesomeness could not be read to int");
///         return false;
///     }
///     return true;
/// }
/// --------------------
///
/// Example Policy type:
/// --------------------
/// struct Policy
/// {
///     /// Maximum possible number of user-defined component types.
///     enum maxUserComponentTypes = 128;
///
///     /// Maximum entities added during one frame.
///     enum maxNewEntitiesPerFrame = 4096;
///
///     /// Minimum size of component buffers (in components) for every
///     /// component type to preallocate.
///     enum minComponentPrealloc = 1024;
///
///     /// The multiplier to increase allocated size during an emergency reallocation.
///     enum reallocMult = 2.5;
///
///     /// Minimum relative size of component buffers (in components) for every
///     /// component type compared to entity count.
///     enum minComponentPerEntityPrealloc = 0.05;
///
///     /// Data type used internally for component counts in an entity.
///     ///
///     /// The max number of components of one type in an entity is ComponentCount.max.
///     /// Using data types such as uint or ulong will increase memory usage.
///     alias ushort ComponentCount;
/// }
/// --------------------
class ComponentTypeManager(Source, Policy = DefaultEntityPolicy)
    : AbstractComponentTypeManager!Policy
{
private:
    /// Loads the Source objects from which entities are loaded.
    Source.Loader sourceLoader;

    /// Set to true after all builtin component types are registered.
    bool builtinRegistered_ = false;

public:
    /// Construct a ComponentTypeManager.
    this(Source.Loader sourceLoader)
    {
        registerComponentTypes!BuiltinComponents;
        builtinRegistered_ = true;
    }

    /// Register specified component types.
    ///
    /// Every component type used any Process registered with the EntityManager must be
    /// registered here. The ComponentTypeID enum member of the component type should be
    /// set by the userComponentTypeID template with an integer parameter with value of
    /// at least 0 and at most Policy.maxUserComponentTypes (64 by default).
    ///
    /// TODO this should link to an .rst article describing the Component concept and
    /// showing example component structs.
    ///
    /// Example:
    /// --------------------
    /// // ComponentTypeManager!SomeSource componentTypes
    /// // struct HealthComponent, struct PhysicsComponent
    /// componentTypes.registerComponentTypes!(HealthComponent, PhysicsComponent);
    /// --------------------
    void registerComponentTypes(Types ...)() @trusted
    {
        assert(!locked, "Can't register new component types with locked "
                        "ComponentTypeManager");
        foreach(Component; Types)
        {
            mixin validateComponent!Component;
            enum id = Component.ComponentTypeID;
            alias attributes = TypeTuple!(__traits(getAttributes, Component));
            static if(staticIndexOf!("defaultsComponent", attributes) != -1)
            {
                const endDefaults =
                    maxBuiltinComponentTypes + maxDefaultsComponentTypes;
                assert(id >= maxBuiltinComponentTypes && id <= endDefaults,
                       "A 'defaults' component type with ID out of range.");
            }
            else
            {
                assert(!builtinRegistered_ || id >= maxReservedComponentTypes,
                       "Registering a component type with ID reserved for builtin "
                       "or 'defaults' component types. Use enum ComponentTypeID = "
                       "userComponentTypeID!YOUR_ID.");
            }
            assert(componentTypeInfo_[id].isNull,
                "There already is a registered component type with this ID");
            static assert(id < maxComponentTypes!Policy,
                "Component type IDs must be at most %s. This limit can be "
                "increased by overriding the Policy template parameter of the "
                "ComponentTypeManager"
                .format(Policy.maxComponentTypes - 1));
            static assert(
                maxComponentsPerEntity!Component <= Policy.ComponentCount.max,
                "maxComponentsPerEntity of a component type is greater than "
                "the maximum value of ComponentCount type specified by the "
                "Policy template parameter of the ComponentTypeManager");
            componentTypeInfo_[id] =
                ComponentTypeInfo.construct!(Source, Component);
        }
    }

    /// Load a Source struct to read components from.
    Source loadSource(const string name) @safe nothrow
    {
        return sourceLoader.loadSource(name);
    }
}
