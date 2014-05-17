//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

// Provides access to all processes packaged with Tharsis by default.
module tharsis.defaults.processes;


import std.typecons;

import tharsis.defaults.components;
public import tharsis.defaults.copyprocess;
import tharsis.defaults.resources;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.entityprototype;
import tharsis.entity.resourcemanager;

import tharsis.util.pagedarray;



/// Reads SpawnerComponents and various spawn conditions and spawns new entities.
///
/// Can be derived to add support for more spawn condition component types.
class SpawnerProcess
{
private:
    /// A function that takes an entity prototype and adds a new entity to the 
    /// EntityManager (at the beginning of the next game update).
    AddEntity addEntity_;

    /// Manages EntityPrototype resources.
    ResourceManager!EntityPrototypeResource prototypeManager_;

    /// Manages entity prototypes defined inline in entities
    /// (in this case, SpawnerMultiComponent.override).
    ResourceManager!InlineEntityPrototypeResource inlinePrototypeManager_;

    /// Entity prototypes to spawn during the next game update.
    ///
    /// Cleared at the beginning of the next game update (after entity manager adds the
    /// new entities).
    PagedArray!EntityPrototype toSpawn_;

    /// Memory used by prototypes in toSpawn_ to store components.
    PartiallyMutablePagedBuffer toSpawnData_;

    /// Type info about all registered component types.
    const(ComponentTypeInfo)[] componentTypes_;

    /// Number of bytes to reserve when creating a prototype to ensure any prototype can
    /// fit.
    size_t maxPrototypeBytes_;

public:
    /// A type of delegates that create a new entity.
    ///
    /// Params:  prototype = Prototype of the entity to create.
    ///
    /// Returns: ID of the newly created entity.
    alias EntityID delegate (ref immutable(EntityPrototype) prototype) @trusted 
        AddEntity;

    /// Construct a SpawnerProcess.
    ///
    /// Params: addEntity              = Delegate to add an entity.
    ///         prototypeManager       = Manages entity prototype resources.
    ///         inlinePrototypeManager = Manages entity prototype resources defined
    ///                                  inline in an entity.
    ///         componentTypeManager   = The component type manager where all used
    ///                                  component types are registered.
    ///
    /// Examples:
    /// --------------------
    /// // EntityManager entityManager
    /// // ResourceManager!EntityPrototypeResource prototypeManager
    /// // ComponentTypeManager componentTypeManager
    /// auto spawner = new SpawnerProcess(&entityManager.addEntity, prototypeManager,
    ///                                   componentTypeManager);
    /// --------------------
    this(Policy)
        (AddEntity addEntity,
         ResourceManager!EntityPrototypeResource prototypeManager,
         ResourceManager!InlineEntityPrototypeResource inlinePrototypeManager,
         ComponentTypeManager!Policy componentTypeManager)
        @safe pure nothrow
    {
        addEntity_              = addEntity;
        prototypeManager_       = prototypeManager;
        inlinePrototypeManager_ = inlinePrototypeManager;
        componentTypes_         = componentTypeManager.componentTypeInfo[];
        maxPrototypeBytes_ = EntityPrototype.maxPrototypeBytes(componentTypeManager);
    }

    /// Called at the beginning of a game update before processing any entities.
    void preProcess()
    {
        // Delete prototypes from the previous game update; they are be spawned by now.
        destroy(toSpawn_);
        toSpawnData_.clear();
    }

    void process(immutable SpawnerMultiComponent[] spawners,
    /// Reads spawners and spawn conditions. Spawns new entities, and doesn't write any
    /// future components.
                 immutable TimedSpawnConditionMultiComponent[] spawnConditions)
    {
        // Spawner components are kept even if all conditions that may spawn them are
        // removed (i.e. if no condition matches the spawnerID of a spawner component).
        // This allows the spawner component to be triggered if a new condition matching
        // its ID is added.
        outer: foreach(ref spawner; spawners)
        {
            // Find conditions matching this spawner component, and spawn if found.
            foreach(ref condition; spawnConditions)
            {
                // Spawn condition must match the spawner component.
                if(condition.spawnerID != spawner.spawnerID) { continue; }

                const baseHandle = spawner.spawn;
                const overHandle = spawner.overrideComponents;

                // If the spawner is not fully loaded yet (any of its resources not in
                // the Loaded state), ignore it completely and move on to the next one.
                //
                // This means we miss spawns when a spawner is not loaded. We may add
                // 'delayed' spawns to compensate for this in future.
                if(!spawnerReady(baseHandle, overHandle)) { continue outer; }

                // We've not reached the time to spawn yet.
                if(condition.timeLeft > 0.0f) { continue; }

                spawn(baseHandle, overHandle);
            }
        }
    }

private:
    /// Are spawner resources ready (loaded) for spawning?
    ///
    /// Starts (async) loading of the resources if not yet loaded.
    ///
    /// Params: baseHandle = Handle to the base prototype of the entity to spawn
    ///                      (e.g. a unit type).
    ///         overHandle = Handle to a prototype storing components added to or
    ///                      overriding those in base (e.g. unit position or other
    ///                      components that may vary between entities of same 'type').
    ///
    /// Returns: True if the resources are loaded and can be used to spawn an entity.
    ///          False otherwise.
    bool spawnerReady(const ResourceHandle!EntityPrototypeResource baseHandle,
                      const ResourceHandle!InlineEntityPrototypeResource overHandle)
    {
        const baseState  = prototypeManager_.state(baseHandle);
        const overState  = inlinePrototypeManager_.state(overHandle);
        if(baseState == ResourceState.New)
        {
            prototypeManager_.requestLoad(baseHandle);
        }
        if(overState == ResourceState.New)
        {
            inlinePrototypeManager_.requestLoad(overHandle);
        }

        return baseState == ResourceState.Loaded && overState == ResourceState.Loaded;
    }

    /// Spawn a new entity created by applying an overriding prototype to a base
    /// prototype.
    ///
    /// Params: baseHandle = Handle to the base prototype of the entity to spawn
    ///                      (e.g. a unit type).
    void spawn(const ResourceHandle!EntityPrototypeResource baseHandle,
    ///         overHandle = Handle to a prototype storing components added to or
    ///                      overriding those in base (e.g. unit position or other
    ///                      components that may vary between entities of same 'type').
               const ResourceHandle!InlineEntityPrototypeResource overHandle)
    {
        // Entity prototype serving as the base of the new entity.
        auto base = prototypeManager_.resource(baseHandle).prototype;
        // Entity prototype storing components applied to (overriding) base to create
        // the new entity.
        auto over = inlinePrototypeManager_.resource(overHandle).prototype;
        // Allocate memory for the new component.
        auto memory = toSpawnData_.getBytes(maxPrototypeBytes_);
        // Create the prototype of the entity to spawn.
        EntityPrototype combined = 
            mergePrototypesOverride(base, over, memory, componentTypes_);

        toSpawnData_.lockBytes(combined.lockAndTrimMemory(componentTypes_));

        // Add the prototype to toSpawn_ to ensure it exists until the
        // beginning of the next game update when it is spawned.  It will be
        // deleted before executing this process during the next game update.

        toSpawn_.appendImmutable(combined);
        // Spawn the entity (at the beginning of the next game update).
        addEntity_(toSpawn_.atImmutable(toSpawn_.length - 1));
    }
}


/// Updates timed spawn condtitions.
///
/// Must be registered with the EntityManager for TimedSpawnConditionComponents to work.
class TimedSpawnConditionProcess
{
private:
    /// A function that gets the length (seconds) of the last game update.
    GetUpdateLength getUpdateLength_;

public:
    /// A function type that gets the length (seconds) of the last game update.
    alias double delegate () @safe pure nothrow GetUpdateLength;

    alias TimedSpawnConditionMultiComponent FutureComponent;

    /// Construct a TimedSpawnConditionProcess using specified delegate to get the time
    /// length of the last game update in seconds.
    this(GetUpdateLength getUpdateLength) @safe pure nothrow
    {
        getUpdateLength_ = getUpdateLength;
    }

    /// Reads and updates timed spawn conditions.
    void process(immutable TimedSpawnConditionMultiComponent[] pastConditions,
                 ref TimedSpawnConditionMultiComponent[] futureConditions)
    {
        size_t index;
        foreach(ref past; pastConditions)
        {
            auto future = &futureConditions[index];
            *future = past;
            if(past.timeLeft <= 0.0)
            {
                // timeLeft < 0 triggers a spawn in SpawnerProcess (if there is a 
                // SpawnerComponent to which this condition applies). After a spawn, if
                // the condition is not periodic, we forget the spawn condition
                // component.
                if(!past.periodic) { continue; }

                // Start the next period.
                future.timeLeft += past.time;
            }

            future.timeLeft -= getUpdateLength_();
            ++index;
        }
        futureConditions = futureConditions[0 .. index];
    } 
}
