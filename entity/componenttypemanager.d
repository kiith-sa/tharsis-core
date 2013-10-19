//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Component type registering, type information management and loading.
module tharsis.entity.componenttypemanager;


import std.algorithm;

import tharsis.entity.componenttypeinfo;


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
    /// Every index corresponds to a component type ID.
    /// If there is no registered component type with a particular ID, the
    /// ComponentTypeInfo at its corresponding index is null.
    ComponentTypeInfo[64] componentTypeInfo_;

public:
    /// Lock the component type manager.
    ///
    /// After this is called, no more types can be registered.
    /// Must be called before passing this manager to an EntityManager.
    void lock() @safe pure nothrow
    {
        assert(!locked_, "Trying to lock a component type manager twice.");
        locked_ = true;
    }

    /// Is this manager locked?
    @property bool locked() @safe const pure nothrow {return locked_;}

    /// Are all specified component types registered?
    bool areTypesRegistered(Types ...)() @safe nothrow const
    {
        foreach(Type; Types) 
        {
            const id = Type.ComponentTypeID;
            if(!componentTypeInfo_[].any!(i => !i.isNull && i.id == id)) 
            {
                return false; 
            }
        }

        return true;
    }

    /// Get the maximum size of all components in a single entity in bytes.
    ///
    /// Can only be called after this manager is locked.
    size_t maxEntityBytes() @safe pure nothrow const 
    {
        assert(locked, "Can't determine max bytes per entity before locking "
                       "ComponentTypeManager");
        size_t result;
        foreach(ref componentType; componentTypeInfo_)
        {
            result += componentType.isNull ? 0 : componentType.size;
        }
        return result;
    }

package:
    /// Get type information about all registered components.
    /// 
    /// Returns a reference to a 64-element array; if there are less than
    /// 64 registered component types, some values will be null 
    /// (determine this using ComponentTypeInfo.isNull).
    /// 
    /// Can only be called after this manager is locked.
    ref const(ComponentTypeInfo[64]) componentTypeInfo()
        @safe pure nothrow const 
    {
        assert(locked, "Can't access component type info before locking "
                       "ComponentTypeManager");
        return componentTypeInfo_;
    }
}


/// Manages component type information and loading.
/// 
/// Before creating an EntityManager, all component types must be registered
/// with a ComponentTypeManager that will be passed to the constructor of an
/// EntityManager.
/// 
/// Params: Source = A struct type to read components from. This may be for 
///                  example a wrapped YAML or XML node, or an INI section.
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
/// Skeleton of a Source struct:
/// --------------------
/// // Note that some manual casting might be required to ensure that methods of 
/// // a Source struct have required attributes (such as pure, nothrow, etc.).
/// //
/// // This can be done safely by ensuring that the method indeed obeys the 
/// // attribute (e.g. ensuring that all exceptions are caught) and manually 
/// // casting any functions that don't obey the attribute.
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
///         /// (There is no requirement to load from actual files;
///         /// this may be implemented by loading from some archive file or 
///         /// from memory.)
///         ///
///         /// On failure, the returned TestSource will be null.
///         TestSource loadSource(string name) @safe nothrow 
///         {
///             assert(false);
///         }
///     }
///
///     /// If true, the Source is 'null' and doesn't store anything. 
///     ///
///     /// A null Source may be returned when loading a Source fails, e.g. 
///     /// from Loader.loadSource().
///     bool isNull() @safe nothrow const
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
///     bool getSequenceValue(string key, out TestSource target) @safe nothrow
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
/// A Source to load components of an entity from should be a mapping with keys 
/// corresponding to lower-case names of component types without the "Component" 
/// suffix. The values corresponding to these keys should be mappings containing 
/// the component's properties.
/// 
/// E.g. to load an int property "awesomeness" of an ExampleComponent,
/// Tharsis will use the Source API roughly in the following way:
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
class ComponentTypeManager(Source) : AbstractComponentTypeManager
{
private:
    /// Loads the Source objects from which entities are loaded.
    Source.Loader sourceLoader;

public:
    /// Construct a ComponentTypeManager.
    this(Source.Loader sourceLoader)
    {
        registerComponentTypes!BuiltinComponents;
    }

    /// Register specified component types.
    /// 
    /// Every component type used any Process registered with the EntityManager
    /// must be registered here.
    /// 
    /// Example:
    /// --------------------
    /// // ComponentTypeManager!SomeSource componentTypes
    /// // struct HealthComponent, struct PhysicsComponent
    /// componentTypes.registerComponentTypes!(HealthComponent, PhysicsComponent);
    /// --------------------
    void registerComponentTypes(Types ...)() @safe
    {
        assert(!locked, "Can't register new component types with locked "
                        "ComponentTypeManager");
        foreach(Component; Types)
        {
            enum id = Component.ComponentTypeID;
            assert(componentTypeInfo_[id].isNull, 
                   "There already is a registered component type with this ID");
            assert(id >= 0 && id < 64, 
                   "Component type IDs must be at least 0 and at most 63.");
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
