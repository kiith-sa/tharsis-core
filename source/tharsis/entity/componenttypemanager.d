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


/** Base class for component type managers.
 *
 * See_Also: ComponentTypeManager.
 */
class AbstractComponentTypeManager
{
private:
    /// Is this manager locked (i.e. no more types may be registered)?
    bool locked_;

protected:
    /** Type information for all registered component types.
     *
     * Every index is a component type ID. If there is no registered component type
     * with a particular ID, the ComponentTypeInfo at that index is null.
     */
    ComponentTypeInfo[] componentTypeInfo_;

public:
    /** Lock the component type manager.
     *
     * After this is called, no more types can be registered. Must be called before
     * passing this manager to an EntityManager.
     */
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

    /** Get the maximum size of all components in any single entity in bytes.
     *
     * Useful when preallocating memory for entity prototypes.
     *
     * Can only be called after this manager is locked.
     */
    final size_t maxEntityBytes() @safe pure nothrow const @nogc
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

    /** Get the maximum number of components (of all types) in a single entity.
     *
     * Can only be called after this manager is locked.
     */
    final size_t maxEntityComponents() @safe pure nothrow const @nogc
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

    /** Get type information about all registered components.
     *
     * Returns a slice; component type IDs are indices to this slice. Some elements may
     * be null (determine this using ComponentTypeInfo.isNull).
     *
     * Can only be called after this manager is locked.
     */
    final const(ComponentTypeInfo[]) componentTypeInfo() @safe pure nothrow const @nogc
    {
        assert(locked, "Can't access component type info before locking "
                       "ComponentTypeManager");
        return componentTypeInfo_;
    }

protected:
    /** Allows AbstractComponentTypeManager to access component type info storage child
     * classes.
     * .
     *
     * Needed as the child class (e.g. ComponentTypeManager) allocates component type info
     * storage by itself based on params such as Policy. (We could make componentTypeInfo_
     * protected, but that would allow a child class to not initialize it.)
     */
    ComponentTypeInfo[] componentTypeInfoStorage() @safe pure nothrow @nogc
    {
        // This is an abstract method. Implemented here only because of a DMD
        // bug (as of DMD 2.065).
        assert(false, "This must not be called; override this in derived class");
    }

private:
    /// AbstracComponentTypeManager constructor, called only by ComponentTypeManager.
    this() @safe pure nothrow @nogc
    {
        componentTypeInfo_ = componentTypeInfoStorage();
    }
}

/// Maximum size of an instance of a Source type in bytes.
enum maxSourceBytes = 512;


/++ Manages component type information and component loading.
 +
 + All component types must be registered with a ComponentTypeManager that will be passed
 + to the constructor of an EntityManager.
 +
 + Params:
 + Source = Struct to read components with, e.g a YAML or XML node or an INI section.
 +          $(B tharsis-full) provides a YAML-based Source implementation. For details,
 +          see $(LINK2 ../../../html/concepts/source.html, Source concept documentation).
 + Policy = Specifies compile-time parameters such as the max number of component types.
 +          See tharsis.entity.entitypolicy for the default Policy type.
 +
 + Example:
 + --------------------
 + // struct SomeSource
 + // SomeSource.Loader loader
 + // AComponent, BComponent, CComponent
 +
 + // Construct the component type manager
 + auto componentTypeMgr = new ComponentTypeManager!SomeSource(loader);
 + // Register a component type
 + componentTypeMgr.registerComponentTypes!AComponent();
 + // Register 2 component types at the same time
 + componentTypeMgr.registerComponentTypes!(BComponent, CComponent);
 + // Lock to disallow further component type changes.
 + // Must be called before passing to EntityManager.
 + componentTypeMgr.lock();
 + // Construct a Scheduler
 + auto scheduler = new Scheduler();
 + // Construct the entity manager.
 + auto entityManager = new EntityManager(componentTypeMgr, scheduler);
 + --------------------
 +
 + Example Policy type:
 + --------------------
 + struct Policy
 + {
 +     /// Maximum possible number of user-defined component types.
 +     enum maxUserComponentTypes = 128;
 +
 +     /// Maximum entities added during one frame.
 +     enum maxNewEntitiesPerFrame = 4096;
 +
 +     /// Minimum number of components of every component type to preallocate space for.
 +     enum minComponentPrealloc = 1024;
 +
 +     /// The multiplier to increase allocated size during an emergency reallocation.
 +     enum reallocMult = 2.5;
 +
 +     /** Minimum number of components of every component type to preallocate space for
 +      * relative to entity count.
 +      */
 +     enum minComponentPerEntityPrealloc = 0.05;
 +
 +     /* Data type used internally for component counts in an entity.
 +      *
 +      * The max number of components of one type in an entity is ComponentCount.max.
 +      * Using data types such as uint or ulong will increase memory usage.
 +      */
 +     alias ushort ComponentCount;
 + }
 + --------------------
 +/
class ComponentTypeManager(Source, Policy = DefaultEntityPolicy)
    : AbstractComponentTypeManager
{
private:
    mixin validateEntityPolicy!Policy;
    mixin validateSource!Source;

    /** Type information for all registered component types.
     *
     * Indices are component type IDs. If there is no registered component type with a
     * particular ID, the ComponentTypeInfo at that index is null.
     */
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

    /** Register specified $(LINK2 component ../../../html/concepts/component.html) types.
     *
     * Every component type used by any Process must be registered. The ComponentTypeID
     * enum member of the component type should be set by the userComponentTypeID template
     * with an integer parameter of at least 0 and at most Policy.maxUserComponentTypes
     * (256 by default).
     *
     * Example:
     * --------------------
     * // ComponentTypeManager!SomeSource componentTypeMgr
     * // struct HealthComponent, struct PhysicsComponent
     * componentTypeMgr.registerComponentTypes!(HealthComponent, PhysicsComponent);
     * --------------------
     */
    void registerComponentTypes(Types ...)() @safe pure nothrow
    {
        assert(!locked, "Can't register component types with locked ComponentTypeManager");
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
                       "Registering a component type with ID reserved for builtin or "
                       "'defaults' component types. Use enum ComponentTypeID = "
                       "userComponentTypeID!YOUR_ID.");
            }
            assert(componentTypeInfoStorage_[id].isNull,
                   "There already is a registered component type with this ID");
            static assert(id < maxComponentTypes!Policy,
                          "Component type IDs must be at most %s. To increase this limit, "
                          "override the Policy template parameter of ComponentTypeManager"
                          .format(Policy.maxComponentTypes - 1));
            static assert(maxComponentsPerEntity!Component <= Policy.ComponentCount.max,
                          "maxComponentsPerEntity of a component type is greater than "
                          "the max value of ComponentCount type specified by the Policy "
                          "template parameter of the ComponentTypeManager");
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
        @safe pure nothrow @nogc
    {
        return componentTypeInfoStorage_[];
    }
}
