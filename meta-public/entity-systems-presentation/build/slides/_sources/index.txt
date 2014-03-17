================
 Entity Systems
================


Game entity
-----------

* *Something* that exists in the game world

  - Rock 
  - Vehicle
  - Trigger 
  - Sound source
  - ...



Game entity
-----------

* An entity may

  - Play a sound
  - Move around 
  - Trigger a script
  - Be used by the player
  - Explode
  - ...
 

Game entity
-----------

* There is a *lot* of different entities in a game 
* Must be easy to create/maintain/modify

  - Preferably without recompiling/repackaging

* Must be efficient
* Game designers shouldn't have to be programmers



OOP entities
------------

* Entities implemented as a class hierarchy

.. figure:: /_static/oop0.png
  :height: 480px
  :align:  center

  https://www.orxonox.net/ticket/229



OOP entities - advantages
-------------------------

* Obvious
* Bad performance 
* Hard to maintain

OOP entities - the Blob
-----------------------

* Kitchen-sink general-purpose classes
* High per-entity overhead
* May be necessary for moddability
* E.g. 'Vehicle', 'Building' in an RTS

  - What about vehicle-buildings?

OOP entities - heavy leaves
---------------------------

* Bad reusability
* Code duplication
* LOTS of classes
* Multiple inheritance or composition with interface

  - Boilerplate
  - Need code to handle each interface
  - Need dynamic casting/RTTI

* Constant refactoring/recompiling

  - Game designers must be programmers


OOP entities - example
----------------------

.. figure:: /_static/oop1.png
  :height: 480px
  :align:  center

  http://www.gdcvault.com/play/1911/Theory-and-Practice-of-the


OOP entities - example
----------------------

.. figure:: /_static/oop2.png
  :height: 480px
  :align:  center

  http://www.gdcvault.com/play/1911/Theory-and-Practice-of-the


OOP entities - example
----------------------

.. figure:: /_static/oop3.png
  :height: 480px
  :align:  center

  http://www.gdcvault.com/play/1911/Theory-and-Practice-of-the


OOP entities - real example
---------------------------

* Close up

.. figure:: /_static/oop_ut.png
  :height: 480px
  :align:  center

  http://www.codekisk.com/unreal/ut3/scriptref/classtree.html

OOP entities - real example
---------------------------

* Zoomed out

.. figure:: /_static/au_actor_tree.png
  :height: 500px
  :align:  center

  http://www.codekisk.com/unreal/ut3/scriptref/classtree.html

Component entities
------------------

* No monolithic *entity* classes

* Data and/or functionality separated into reusable, self-contained *components*

* Components should be small, atomic, easy to write

* Arbitrary components *aggregated* into entities 

  - Preferably at runtime
  - Preferably from data (no recompilation)
  - Easy to add/test/change entities
  - Redeemer example

Component entities cont.
------------------------

* An entity has *only* the functionality it needs

  - And uses only the resources it needs

* Each entity may have different components 

  - In Java terms, every entity is a separate class
  - Leads to an explosion of possible component combinations

* Optionally, components in an entity may be changed at runtime

  - In Java terms, class of an entity may change
  - Mobile trap example

Component entities - component examples
---------------------------------------

* Position 
* Collision volume
* Physical material
* Graphics 
* Animation
* AI


Component entities - entity example
-----------------------------------

.. code::

   visual: visual/harpooner.yaml
   engine:
     maxSpeed: 250
     acceleration: 2500
   volume:
     aabbox: 
       min: [-25, 0]
       max: [25, 30]
   weapon:
     0: weapons/harpoonLauncher.yaml
   collidable:
   health: 55
   warhead:
     damage: 45
     killsEntity: false
   dumbScript: dumbscripts/arrows.yaml
   score:
     exp: 120

Component entities - organized blob
-----------------------------------

* An entity class with NULLable pointers to components
* Quick & dirty, easy to implement 
* May be good enough if not many component types
* Quite a lot of memory overhead
* CPU overhead, allocation simple


Component entities - organized blob
-----------------------------------

.. code::

   class Entity 
   {
       // These may be null
       PhysicsComponent* physics;
       GraphicsComponent* graphics;
       AIComponent* ai;
       CollisionVolumeComponent* volume;

       ...
       Lots of pointers (~10 - ~300)
       ...
   };


Component entities - container of components
--------------------------------------------

* Component classes implementing a *Component* interface/class
* An entity owns a container of *Components*
* There still is an *Entity* object which may have some extra baggage


Component entities - entity-component system (ECS)
--------------------------------------------------

* No *Entity* object 

  - "Entity" is just a unique ID
  - Code works with individual components, not entities

.. figure:: /_static/ecs.png
  :height: 400px
  :align:  center

  http://cowboyprogramming.com/2007/01/05/evolve-your-heirachy/


Execution in a naive ECS (OOP components)
-----------------------------------------

* High-level concept. May not reflect reality.

.. code::

   foreach(componentType)
   {
       foreach(entity) 
       {
           getComponent(componentType, entity).update();
       }
   }


OOP components - issues
-----------------------

* Components must access each other 

  - References between components 

    * Init/deinit dependency issues 
    * Leads to dependency chains (even circular)
    * Harder to remove/change components

  - Indirect communication (slow, nontrivial)

  - Blob component

  - Need virtual functions and/or RTTI

  - Order of updates matters

    * Refactoring may break the game


RDBMS style ECS
---------------

* Idea: OOP is a bad model for game entities (or components)

* Logic separated from data 

* May be implemented in an OOP language, but is not OOP 


RDBMS style ECS
---------------

* Entity: 

  - Like a object (1 entity - 1 instance)
  - Like a class (each entity defines its own behavior)
  - Is neither
  - Implementation - unique ID, no data, no methods

* Component

  - Plain data, no logic 
  - Implementation e.g. a C struct
  - "A Component is the chunk of stuff that provides a particular aspect to an Entity"

RDBMS style ECS: System
-----------------------

* System (or Process)

  - A reusable, self-contained, piece of logic; replaces methods
  - Specifies component types it operates on 
  - Processes every entity containing (all of) those components

    * Similar to an SQL SELECT (not necessarily the same)

* System examples (often match components):

  - Input
  - Graphics 
  - Collision 
  - AI 


RDBMS style ECS: System - example
---------------------------------

.. code::

    class PhysicsSystem : System 
    {
        private:
            const GameTime gameTime_;

        public:
            void process(ref PositionComponent pos, ref VelocityComponent vel) 
            {
                pos.position += gameTime_.timeStep * vel.velocity;
            }
    }

RDBMS style ECS: System - execution
-----------------------------------

* High-level concept. **Does not** reflect reality.


.. code::

   foreach(system; systems)
   {
       foreach(entity; entities)
       {
           if(entity.hasComponents(system.processedComponents()))
           {
               system.process(entity.getComponents(system.processedComponents()));
           }
       }
   }


RDBMS style ECS: advantages
---------------------------

* **No** references to/dependencies on other components

  - Combine anything with anything

* No inter-component communication 

* Systems can be trivially added/removed

* No virtuals or dynamic casting (despite the previous slide)

* Can be exploited for performace


RDBMS style ECS: implementation example
---------------------------------------
.. rst-class:: build

* Arrays (easy to implement)

* *Arrays* (save memory)

* **Arrays** (CPU cache)

* May not be trivial arrays. But they should be contiguous in memory.
  


RDBMS style ECS: implementation example
---------------------------------------

* Assign an index to every component type.

  - E.g. Position: 0, Graphics: 1, Volume: 2

* An array of bits can specify which components an entity consists of.

  - 101: Position, Volume
  - 001: Volume

* A 64bit integer can be used as an array of bits.

  - Up to 64 component types. If not enough, use 2 or more integers.


RDBMS style ECS: implementation example
---------------------------------------


.. code::

  uint[] entityIDs;

  ulong[] componentFlags;

* entityIDs.length == componentFlags.length

* componentFlags[*i*] specifies components of entity entityIDs[*i*]


RDBMS style ECS: implementation example
---------------------------------------

.. code::

  // One array for every component type (use templated code or pointers/casting
  // to support any number of component types)

  Position[] positionComponents;
  Graphics[] graphicsComponents;
  Volume[]   volumeComponents;

* Components match the order of entities 

  - 1 or 0 components per entity


RDBMS style ECS: implementation example
---------------------------------------

.. code::

  foreach(system; systems)
  {
      ulong flags = system.componentFlags();
      uint[flags.length] componentIndices;
      componentIndices[] = 0;

      for(uint entityIndex = 0; entityIndex < entityIDs.length; entityIndex++)
      {
          incrementComponentIndices(componentFlags[entityIndex], componentIndices);
          if(componentFlags[entityIndex] && flags)
          {
              system.process(getComponents(componentIndices));
          }
          // increment component indices corresponding to flags
      }
  }

* *Close* to reality
* Use templates/code generation to avoid virtuals, allow inlining

RDBMS style ECS: implementation example
---------------------------------------

* Very little pointer-chasing, iterates over linear data 

  - Data we're about to read is often already in CPU cache
  - Often predictable branching

* Easy to keep track of memory usage (by component type)

* Easy to keep track of CPU usage (by system)

* Further optimizations possible 

  - Alignment to cache line size
  - Manual prefetch

The machine matters
-------------------

* Modern x86 CPU:

  -  CPU cycle:            ~0.3 ns
  -  Branch misprediction: ~5 ns
  -  L1 cache miss:        ~7 ns
  -  Lmax miss:            ~100 ns

* (Much) Worse on ARM, PowerPC (X360/PS3/WiiU).

  - Also - virtual call usually 1-2 Lmax misses
 
* 5k entities * 30 components (avg) * 100ns (Lmax miss) = 15 ms 

* At 60FPS we have 16.66ms per frame

ECS: projects
-------------

* Artemis: http://gamadu.com/artemis/

* EntityX: https://github.com/alecthomas/entityx 

* Unity3D: http://unity3d.com/

* Unreal Engine 4: http://www.unrealengine.com/unreal_engine_4/


Sources
-------

* http://cowboyprogramming.com/2007/01/05/evolve-your-heirachy/

* http://twvideo01.ubm-us.net/o1/vault/GD_Mag_Archives/GDM_November_2011.pdf

* https://d3cw3dd2w32x2b.cloudfront.net/wp-content/uploads/2011/06/6-1-2010.pdf

* http://t-machine.org/index.php/2007/09/03/entity-systems-are-the-future-of-mmog-development-part-1/


Thank you
---------

* And stuff
