//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.defaults.processes;


import tharsis.defaults.components;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.entityprototype;
import tharsis.entity.resourcemanager;



/// Reads SpawnerComponents and various spawn conditions and spawns new entities.
///
/// Can be derived to add support for more spawn condition component types.
class SpawnerProcess
{
private:
    /// A function that takes an entity prototype and adds a new entity.
    AddEntity addEntity_;

    /// Manages EntityPrototype resources.
    ResourceManager!EntityPrototypeResource prototypeManager_;

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
    /// Params: addEntity        = Delegate to add an entity.
    ///         prototypeManager = Manages entity prototype resources.
    ///
    /// Examples:
    /// --------------------
    /// // EntityManager entityManager
    /// // ResourceManager!EntityPrototypeResource prototypeManager
    /// auto spawner = new SpawnerProcess(&entityManager.addEntity,
    ///                                   prototypeManager);
    /// --------------------
    this(AddEntity addEntity,
         ResourceManager!EntityPrototypeResource prototypeManager)
        @safe pure nothrow
    {
        addEntity_        = addEntity;
        prototypeManager_ = prototypeManager;
    }

    /// Reads spawners and spawn conditions. It spawns new 
    /// entities, and doesn't write any future components.
    void process(immutable SpawnerMultiComponent[] spawners,
                 immutable TimedSpawnConditionMultiComponent[] spawnConditions)
    {
        outer: foreach(ref spawner; spawners)
        {
            foreach(ref condition; spawnConditions)
            {
                // Don't even consider combinations where the spawner ID doesn't
                // match.
                if(condition.spawnerID != spawner.spawnerID) { continue; }

                // Regardless of spawn time, if spawner ID does match, we will
                // likely want to spawn this sooner or later, so make sure the 
                // prototype is loaded.
                const protoHandle = spawner.spawnPrototype_;
                const state = prototypeManager_.state(protoHandle);
                if(state == ResourceState.New)
                {
                    prototypeManager_.requestLoad(protoHandle);
                }

                // We've not reached the time to spawn yet.
                if(condition.timeLeft > 0.0f) { continue; }

                // We simply don't spawn if the prototype of the entity to spawn
                // is not yet loaded. In future, we might add 'delayed' spawns.
                if(state != ResourceState.Loaded)
                {
                    // Regardless of the condition, this spawner's prototype is
                    // not loaded yet, so skip to the next spawner.
                    continue outer;
                }

                // Spawn the entity.
                addEntity_(prototypeManager_.resource(protoHandle).prototype);
            }
        }
    }
}


/// Updates timed spawn condtitions.
///
/// Must be registered with the EntityManager for TimedSpawnConditionComponents
/// to work.
class TimedSpawnConditionProcess
{
private:
    /// A function that gets the length (seconds) of the last game update.
    GetUpdateLength getUpdateLength_;

public:
    /// A function type that gets the length (seconds) of the last game update.
    alias double delegate () @safe pure nothrow GetUpdateLength;

    alias TimedSpawnConditionMultiComponent FutureComponent;

    /// Construct a TimedSpawnConditionProcess using specified delegate to get 
    /// the time length of the last game update in seconds.
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
                // timeLeft < 0 triggers a spawn in SpawnerProcess (if there is 
                // a SpawnerComponents to which this condition applies). After a 
                // spawn, if the condition is not periodic, we can forget the
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
