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
import tharsis.entity.source;


/// Base class for component type managers.
///
/// See_Also: ComponentTypeManager.
class AbstractComponentTypeManager
{
private:
    /// Is this manager locked (i.e. no more types may be registered)?
    bool locked_;

protected:
    /// Type information for all registered component types.
    ///
    /// Every index is a component type ID. If there is no registered component type
    /// with a particular ID, the ComponentTypeInfo at that index is null.
    ComponentTypeInfo[] componentTypeInfo_;

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
    final @property bool locked() @safe const pure nothrow @nogc { return locked_; }

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
    final const(ComponentTypeInfo[]) componentTypeInfo() @safe pure nothrow const @nogc
    {
        assert(locked, "Can't access component type info before locking "
                       "ComponentTypeManager");
        return componentTypeInfo_;
    }

protected:
    /// Provides access to component type info storage (in a derived class) to
    /// AbstractComponentTypeManager.
    ///
    /// This is used because the derived class (e.g. ComponentTypeManager) will
    /// allocate the component type info storage by itself depending on its
    /// parameters (e.g. Policy). (We could just make componentTypeInfo_
    /// protected, but that would allow ComponentTypeManagers that don't
    /// initialize it).
    ComponentTypeInfo[] componentTypeInfoStorage() @safe pure nothrow
    {
        // This is an abstract method. Implemented here only because of a DMD
        // bug (as of DMD 2.065).
        assert(false,
               "This must not be called; override this in derived class");
    }

private:
    /// AbstracComponentTypeManager constructor, called only by ComponentTypeManager.
    this() @safe pure nothrow
    {
        componentTypeInfo_ = componentTypeInfoStorage();
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
///                  wrapped YAML or XML node, or an INI section. $(B tharsis-full)
///                  provides a Source implementation based on YAML. See below if you
///                  need to create your own implementation.
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
/// componentTypes.registerComponentTypes!(BComponent, CComponent);
/// // Lock to disallow further component type changes.
/// // Must be called before passing to EntityManager.
/// componentTypes.lock();
/// // Construct the entity manager.
/// auto entityManager = new EntityManager(componentTypes);
/// --------------------
///
/// Limitations of a Source struct:
///
/// sizeof of a Source can be at most maxSourceBytes (512 at the moment). A Source must
/// be copyable; if it includes nested data (such as JSON/XML/YAML subnodes), copying a
/// Source must either also copy this nested data or share it by using e.g. reference
/// counting or garbage collector managed storage.
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
///         /** Load a Source with specified name (e.g. entity file name).
///          *
///          *
///          * Params: name      = Name to identify the source by (e.g. a file name).
///          *         logErrors = If true, errors generated during the use of the Source
///          *                     (such as loading errors, conversion errors etc.)
///          *                     should be logged, accessible through the errorLog()
///          *                     method of Source.
///          *
///          * There is no requirement to load from actual files; this may be
///          * implemented by loading from some archive file or from memory.
///          */
///         TestSource loadSource(string name, bool logErrors) @safe nothrow
///         {
///             assert(false);
///         }
///     }
///
///     /** If true, the Source is 'null' and doesn't store anything.
///      *
///      * A null Source may be returned when loading a Source fails, e.g. from
///      * Loader.loadSource().
///      */
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
///     /** Read a value of type T to target.
///      *
///      * Returns: true if the value was successfully read.
///      *          false if the Source isn't convertible to specified type.
///      */
///     bool readTo(T)(out T target) @safe nothrow
///     {
///         assert(false);
///     }
///
///     /** Get a nested Source from a 'sequence' Source.
///      *
///      * (Get a value from a Source that represents an array of Sources)
///      *
///      * Can only be called on if the Source is a sequence (see isSequence()).
///      *
///      * Params:  index  = Index of the Source to get in the sequence.
///      *          target = Target to read the Source to.
///      *
///      * Returns: true on success, false if index is out of range.
///      */
///     bool getSequenceValue(size_t index, out TestSource target) @safe nothrow
///     {
///         assert(false);
///     }
///
///
///     /** Get a nested Source from a 'mapping' Source.
///      *
///      * (Get a value from a Source that maps strings to Sources)
///      *
///      * Can only be called on if the Source is a mapping (see isMapping()).
///      *
///      * Params: key    = Key identifying the nested source..
///      *         target = Target to read the nested source to.
///      *
///      * Returns: true on success, false if there is no such key in the mapping.
///      */
///     bool getMappingValue(string key, out TestSource target) @safe nothrow
///     {
///         assert(false);
///     }
///
///     /// Is this a scalar source? A scalar is any source that is not a sequence or a mapping.
///     bool isScalar() @safe nothrow const
///     {
///         assert(false);
///     }
///
///     /// Is this a sequence source? A sequence acts as an array of values of various types.
///     bool isSequence() @safe nothrow const
///     {
///         return yaml_.isSequence();
///     }
///
///     /// Is this a mapping source? A mapping acts as an associative array of various types.
///     bool isMapping() @safe nothrow const
///     {
///         return yaml_.isMapping();
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
    : AbstractComponentTypeManager
{
private:
    mixin validateEntityPolicy!Policy;
    mixin validateSource!Source;

    /// Type information for all registered component types.
    ///
    /// Indices are component type IDs. If there is no registered component type with a
    /// particular ID, the ComponentTypeInfo at that index is null.
    ComponentTypeInfo[maxComponentTypes!Policy] componentTypeInfoStorage_;

    /// Loads the Source objects from which entities are loaded.
    Source.Loader sourceLoader_;

    /// Set to true after all builtin component types are registered.
    bool builtinRegistered_ = false;

public:
    /// Construct a ComponentTypeManager.
    this(Source.Loader loader) @safe pure nothrow
    {
        registerComponentTypes!BuiltinComponents;
        builtinRegistered_ = true;
        sourceLoader_      = loader;
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
    void registerComponentTypes(Types ...)() @safe pure nothrow
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
                const endDefaults = maxBuiltinComponentTypes + maxDefaultsComponentTypes;
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
            assert(componentTypeInfoStorage_[id].isNull,
                   "There already is a registered component type with this ID");
            static assert(id < maxComponentTypes!Policy,
                          "Component type IDs must be at most %s. This limit can be "
                          "increased by overriding the Policy template parameter of "
                          "the ComponentTypeManager"
                          .format(Policy.maxComponentTypes - 1));
            static assert(maxComponentsPerEntity!Component <= Policy.ComponentCount.max,
                          "maxComponentsPerEntity of a component type is greater than "
                          "the max value of ComponentCount type specified by the "
                          "Policy template parameter of the ComponentTypeManager");
            componentTypeInfoStorage_[id].__ctor!(Source, Component);
        }
    }

    /** Get the Source loader used to load components from Sources.
     *
     * Note that while it is possible to modify the loader, doing so will be at your own
     * risk; ComponentTypeManager doesn't expect the loader to change.
     */
    ref Source.Loader sourceLoader() @safe nothrow @nogc { return sourceLoader_; }


protected:
    final override ComponentTypeInfo[] componentTypeInfoStorage()
        @safe pure nothrow
    {
        return componentTypeInfoStorage_[];
    }
}
