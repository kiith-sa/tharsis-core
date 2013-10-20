=================================================
Tharsis: Threaded Entity-Component Framework in D
=================================================

**NOTE: This is a design document;  it does not describe a finished product and
is subject to change**

Tharsis is an open-source
`Entity Component System <en.wikipedia.org/wiki/Entity_component_system>`_
framework written in the `D programming language <dlang.org>`_ with support for 
automatic threading of game/simulation code.

               

------------
Introduction
------------


Most past (and many present) game engines use an inheritance-based approach to
design game entities. This approach is intuitive but gets unwieldy as the
entities get more complex. This led to the adoption of entity systems based on
aggregation instead of inheritance, many of which are referred to as
*entity-component* systems.  
`This <http://cowboyprogramming.com/2007/01/05/evolve-your-heirachy/>`_ 
`has <http://scottbilas.com/files/2002/gdc_san_jose/game_objects_slides.pdf>`_ 
`been <http://gamearchitect.net/Articles/GameObjects1.html>`_
`discussed <https://d3cw3dd2w32x2b.cloudfront.net/wp-content/uploads/2011/06/6-1-2010.pdf>`_
`to <http://www.gamedev.net/page/resources/_/technical/game-programming/understanding-component-entity-systems-r3013>`_
`death <http://flohofwoe.blogspot.sk/2007/11/nebula3s-application-layer-provides.html>`_
`already <http://www.richardlord.net/blog/what-is-an-entity-framework>`_,
so this article focuses on the specifics of the Tharsis framework.

Many early component systems use entities composed of "intelligent" components
with their own logic logic usually implementing some kind of an interface. This
approach has various issues, including the dependency of a components' logic on
another component.

Tharsis entities consist of "dumb" components that are pure data with no logic
whatsoever, similar to the approach proposed by 
`Adam Martin <t-machine.org/index.php/2007/09/03/entity-systems-are-the-future-of-mmog-development-part-1/>`_.

With this approach, all logic is separated into "systems" (or *processes*, as
they're called in Tharsis). A process is usually (ideally) a stateless object
with a method that is called for all entities containing components specified
in its signature.  This decouples data and code and avoids component
dependencies; code depending on particular components will only execute if
those components are present.

Another advantage of dumb components is performance; components can be
plain-old-data types with no virtual functions and can often by tightly packed
in memory.

Tharsis builds on this approach, adding a distinction between *past* and
*future* state which removes dependencies of processes on the order in which
they are being run and enables performance optimizations such as execution of
processes on different threads.

--------
Features
--------

^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Separation of data and logic
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Components in Tharsis are plain-old-data with no logic.  Logic is fully
contained in *processes*, often called systems in other entity component
systems.

^^^^^^^^^^^^^^^^^^^^^
Data-defined entities
^^^^^^^^^^^^^^^^^^^^^

Tharsis automatically generates code to load components from user-specifiable 
*Sources* (see below in the *Concepts* section). YAML support is built-in;
support for XML, JSON or other formats can be added by defining a struct with 
a very simple interface.

^^^^^^^^^^^^^^^^^^^^^^^
Past/future distinction
^^^^^^^^^^^^^^^^^^^^^^^

Unlike in other frameworks, components and entities in Tharsis exist in two
versions; read-only *past* and writable *future*. This removes the dependencies
of processes on the order in which they run; all processes read the unchanged
state from previous frame.

During a frame, processes read past components to write future components
(which are created on-the-fly). When all processes have finished processing,
the frame ends, future becomes the past, and memory formerly allocated for past
is reused for future state created during the next frame.

Since future components are created as the process runs, the process can add or
remove (i.e. not add) components while the data is stored linearly, avoiding
dead gaps and subsequent cleanup.  If an entity is removed, its components are
simply not added In the future.

^^^^^^^^^
Threading
^^^^^^^^^

All processes in Tharis read immutable data from the past; one process can't
affect what another reads during a frame. Also, only one process can write
future components of one type. While this is somewhat limiting, it allows the
processes to be moved into separate threads automatically, adapting to the
number of cores of the CPU.

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Generated code for safety and performance
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Components in Tharsis are always structs and processes don't need to be
polymorphic; Tharsis analyzes signature of the *process()* method of a process
and generates code that will call it directly without indirections.  This
enables inlining and other compiler optimizations.

The *process()*  method is only called if an entity has all past components
from its signature.  There is no need to cast or to determine if a component is
present. Component iteration is not implemented by convention; it is built into
the framework, allowing further optimizations such as threading.

^^^^^^^^^^^^^^^^^^^^^^^^^^^
Cache-friendly memory usage
^^^^^^^^^^^^^^^^^^^^^^^^^^^

Tharsis allocates memory through user-specified allocation functions (default
being malloc/free). Memory for components and entities is preallocated based on
compile-time hints (e.g. if a component type is common, one can specify that at
least 16k components of that type should be preallocated) as well as run-time
controls (e.g. increase the size of preallocated memory before loading a large
map).

If Tharsis runs out of memory and is forced to reallocate in the middle
a frame, it prints a warning, allowing the programmer to adjust size of
preallocated memory.

Components and entities are tightly packed in simple arrays processed linearly
to avoid cache misses.

---
API
---

This section describes the main types and concepts in Tharsis API.  Note that
the implementation may involve more types.


^^^^^^^^^^^^^^^^^^^
Component (concept)
^^^^^^^^^^^^^^^^^^^

* Simple struct types defined by the programmer

  - Registered and verified by ComponentTypeManager
  - No elaborate destructor, copy constructor or postblit
  - Data behind any indirections is not owned by the component 

    * E.g. resource handles (initialization not certain yet)
  - Can be safely compied by memcpy
* Compile-time information:

  - Unique type ID (set manually by the user, validated at runtime)
  - Optional preallocation hints 
* Type name must have a "Component" suffix (may be relaxed if inconvenient)
* Builtin components (avoided if possible)

  - LifeComponent - determines if an entity is dead and should be removed

Example ::

    struct StaticComponent
    {
        enum ushort ComponentTypeID = maxBuiltinComponentTypes + 1;

        enum minPrealloc = 16384;

        enum minPreallocPerEntity = 1.0;

        vec3 position;

        vec3 rotation;
    }

^^^^^^^^^^^^^^^^^^^^^^^^
MultiComponent (concept)
^^^^^^^^^^^^^^^^^^^^^^^^

* A Component allowing more than one instance per entity
  - Differentiated by a compile-time flag or naming convention (not certain yet)
* Passed to processes as a slice 
* Extra compile-time information: 
  - Maximum components of this type per entity 

Example::

   struct ColliderMultiComponent 
   {
       enum ushort ComponentTypeID = maxBuiltinComponentTypes + 2;

       enum isMultiComponent = true;

       enum maxComponentsPerEntity = 1024;

       EntityID colliderEntityID;
   }

^^^^^^^^^^^^^^^^^
Process (concept)
^^^^^^^^^^^^^^^^^

* Class types with a process() method (without deriving a common parent)
* Signature of a process() method:

  - Optional reference to immutable past entity
  - References to immutable past components

    * For MultiComponents, these are slices of immutable components
  - Optional output reference to mutable future componen

    * May be an output reference to mutable pointer; the pointer can be (and,
      due to the output reference, is by default) set to null to avoid writing
      the component to future state.
    * For MultiComponent, this is an output reference to a slice of mutable
      components with length equal to maxComponentsPerEntity of that
      MultiComponent type. The slice is shortened to specify the the part
      written to future state.

* Multiple process() methods can be used to match different past component
  patterns (at some performance cost). If component patterns of two process()
  methods are ambiguous, a compile-time error informs the programmer about
  a need to define another process() function to handle a union of these
  patterns.  More specific process() methods take precedence over more general
  ones.

* A process may contain compile-time information related to scheduling such as
  the number of frames it can skip, or to allow optimizations in code generated
  to call its process() method/s. This information will be defined as the
  scheduling code is implemented.

Example::

   class MovementProcess 
   {
       /// A more specific process() method, taking precedence if there is 
       /// both a StaticComponent and a DynamicComponent.
       void process(ref immutable(StaticComponent) pastStatic,
                    ref immutable(DynamicComponent) pastDynamic,
                    out StaticComponent futureStatic)
       {
           // How to determine time is not yet determined, 
           // this is just an example.
           futureStatic.position = pastStatic.position + 
                                   timeStep * pastDynamic.velocity;
       }

       /// A more general case, ensuring the the component is preserved 
       /// in future state (this particular case may be simplified/optimized 
       /// further with a compile-time flag if overhead is measurable).
       void process(ref immutable(StaticComponent) pastStatic,
                    out StaticComponent futureStatic)
       {
           futureStatic = pastStatic;
       }
   }

^^^^^^^^^^^^^^^
Entity (struct)
^^^^^^^^^^^^^^^

* Stores a unique ID (*EntityID*)
* By itself, it has no data about the components it contains 

  - *Component counts* are stored by EntityManager in arrays parallel to the
    entity array; a Process writes to the component counts array for its future
    component type, removing the need to lock entities.

^^^^^^^^^^^^^^^^^^^^^^^^
EntityPrototype (struct)
^^^^^^^^^^^^^^^^^^^^^^^^

* Stores components needed to create an entity 
* Can be loaded from a file once, used to create many entities
* Does not manage its memory (memory can be provided by e.g. a ResourceManager)

^^^^^^^^^^^^^^^^
Source (concept)
^^^^^^^^^^^^^^^^

* Used by generated code to load Component properties
* User-overridable (at compile-time) type to load components from (e.g. into
  EntityPrototypes)
* Usually should be a wrapper around a serializing format such as XML, JSON,
  YAML. YAML support is implemented by builtin YAMLSource
* Must be able to represent mappings, sequences, values

^^^^^^^^^^^^^^^^^^
Resource (concept)
^^^^^^^^^^^^^^^^^^

* Struct types designed to be created once, used without mutation

  - May contain large chunks of data loaded from files, such as images, 
    sounds, 3D models, EntityPrototypes, ...
  - Created once, marked immutable, reused many times from many threads 
  - Must define two struct types: Descriptor and Handle

    * Descriptor contains all information needed to create the resource 
      (e.g. a filename)
    * Handle is an ID used to access a Resource through its ResourceManager

Example::

   struct EntityPrototypeResource 
   {
       struct Handle 
       {
       package:
           /// Accessible only by a ResourceManager in the same package
           uint resourceID_ = uint.max;
       }

       struct Descriptor 
       {
           string fileName;
       }

       this(const ref Descriptor descriptor) @safe pure nothrow
       {
           this.descriptor = descriptor;
       }

       // As the resource is accessed through immutable references, its data 
       // members can be public. The resource manager can directly change them 
       // until marked immutable.

       EntityPrototype prototype;

       Descriptor descriptor;

       ResourceState state = ResourceState.New; 
   }

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
ResourceManager (class hierarchy)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

* AbstractResourceManager - common base

  - Allows EntityManager to "run" the ResourceManager
* ResourceManager!Resource - base of resource-specific managers

  - API to use Resources with
  - Resource creation, loading, access, state queries
* Implementation classes 

  - Implement ResourceManager!Resource API 
  - Store resources in (logically) immutable storage 

^^^^^^^^^^^^^^^^^^^^^
EntityManager (class)
^^^^^^^^^^^^^^^^^^^^^

* The main "master" object
* Entity creation (done between frames)
* Entity/component storage
* Resource manager registering
* Process registering/validation
* Executing processes
* Configured at compile-time by a policy with limits, hints

^^^^^^^^^^^^^^^^^^^^^^^^^^^^
ComponentTypeManager (class)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

* Component type registering/validation
* Component type info generation
* Configured at compile-time by a policy with limits, hints

--------------------
Execution of a frame
--------------------

This is a high-level overview of what EntityManager needs to do between frames.
Note that this is very likely to change as any unexpected issues appear.

* Wait until all processes running in threads stop (don't stop the threads)
* Run resource managers 
  (allowing them to load resources, possibly in background threads)
* Switch past/future component buffers 
* Reallocate memory if running out (this should not happen often)
* Create entities added during the last frame 
* Switch past/future entity buffers 
* Copy the past (former future) entities to future, forgetting dead entities
* ? Handle messages ?
* Assign processes to threads 
* Run processes in threads

----------------------
Execution of a process
----------------------

This is a high-level overview of what the generated code executing a Process
needs to do every frame. As above, this is very likely to change.

* For each past entity
 
  - If the entity is not dead
  
    * If the entity has all needed components 
  
      - Ensure we have enough memory (running out of memory here should be
        very rare, and this check could even be removed based on
        preallocation hints).
      - Call (one of) the process() method(s)
  
    * Update the component count on the future component
    * ? Optionally update a spatial manager based on this component ?
  - Iterate over components relevant to the process 


-----------------------------------
Uncertain features / to be designed
-----------------------------------

* Message-passing between systems (always delayed by 1 frame).
  - May not be needed at all
* Spatial management (needed for e.g. collision detection)
  - Should be user-defined


-----
Goals
-----

- Main goals

  * A past/future entity system 

    - Separation into past and future state
    - Future state is generated on-the-fly 
    - Resources loaded async between frames (but not in separate threads)
    - Entities loaded from files using compile-time generated information,
      including resource initialization.
    - Performance measurements

  * Threading 

    - Processes executed on separate threads
    - Solving uncertain/unforseen issues.

      * Messaging ?
      * Spatial management ?
    - Performance measurements
  * Scheduling 

    - Processes assigned to threads according to user hints and/or (very basic)
      real-time profiling
    - Performance measurements
  * Optimizations
- Optional goals

  * Threaded resource loading
    - Resources loaded async in background threads
  * Special-case optimizations in generated code


--------------------------
Non-goals (aka beyond-1.0)
--------------------------

* Parallelization on the level of entities as opposed to (or in addition to)
  processes 

  - Past-future distinction is the main requirement enabling this approach
  - Possible, but would complicate the design (memory organization)
  - Not very useful in most cases on <10 core machines
* Parallelization on the GPU 

  - Will require massive changes
  - May be revisited once unified address space is common 
  - May only be useful with entity-level parallelization
* Scripting language support 


----------------------------------------
Other component-entity system frameworks
----------------------------------------

* `Artemis <http://gamadu.com/artemis/>`_ (Java), 
  (`D port <https://github.com/elvisxzhou/artemisd/tree/master/source>`_), 
  (`C++ clone <http://www.acunliffe.com/2013/01/coment-a-c-componententity-system-based-on-artemis/>`_)
* `EntityX <https://github.com/alecthomas/entityx>`_ (C++) - 
  a type-safe entity system with some similarities to Tharsis
* `Ash <http://www.ashframework.org/>`_ (ActionScript 3)
* `dtEntity <http://code.google.com/p/dtentity/>`_ (C++)
* `Entreri <https://bitbucket.org/mludwig/entreri>`_ (Java)
* `Unity3D engine <http://unity3d.com/>`_ (uses a component-entity system)
