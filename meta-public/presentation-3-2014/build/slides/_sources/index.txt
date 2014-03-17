=====================================================================
A concurrent component-based entity architecture for game development
=====================================================================

:Author:
    Ferdinand Majerech
:Supervisor:
    RNDr. Jozef Jirásek, PhD.

Previously on SAI
-----------------

* Entity systems

  - OOP
  - OOP components w/ methods
  - RDBMS-style

    * Components - data
    * Systems - logic
    * Arrays

Issues with existing ECS's
--------------------------

* Implicit, unexpected dependencies on system run order

  - Run order: ASystem, BSystem, CSystem
  - ASystem may modify inputs of BSystem

    * Outputs of BSystem may further affect:

      - CSystem
      - ASystem the on next game update

    * These chains get worse
    * Breakages when adding/removing/reordering systems


Issues with existing ECS's
--------------------------

* Manual synchronization needed for threading

  - Often too much overhead (locking)
  - Always difficult
  - Often fixed to a single thread

    * Or a fixed number of threads (e.g. for specific hardware)

Tharsis
-------

* Entity system (framework)

  - Open source (Boost)
  - Written in D
  - Platform independent
  - *Automatic threading (* **TBD** *)*

Tharsis
-------

Should have all the good stuff
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

* Easy to modify entities
* Lightweight components
* Data defined, no programmer needed
* Entity as a dumb ID
* Data in *Components*, logic in Systems (called *Processes*)


Tharsis
-------

New stuff (goals)
^^^^^^^^^^^^^^^^^

* Process run order should not matter

  - It may even change at runtime due to scheduling

* Threading should be automatic (unless specified by the user)

  - Lock only when absolutely necessary
  - Work with varying core counts (up to ... many)
  - Scheduling to evenly spread the load, avoid spikes

* No ugly voidpointery macroy stuff in the API

  - Type-safe

* Generated code to exploit Process specifics for optimization

  - Usually, this means 'don't do what you don't have to'

Tharsis
-------

More stuff turned out to be necessary
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

* Compile-time constraints on what the user can do (e.g. in a Process)

  - Easier than hand-crafting a game for multiple cores

  - Not as convenient as working with an ECS in a single thread

* Resource management designed to minimize locking

  - Immutable resources
  - Not really a big focus (yet), but necessary

* MultiComponents

  - This is where the RDBMS analogy breaks down
  - Surprisingly convenient

Past and future
---------------

Past 
^^^^

* Game state (components) from the previous game update
* Processes can read, but not write, past data

  - Past data is immutable during a game update


Past and future
---------------

Future
^^^^^^

* Game state created during the current game update
* Written by Processes
* A Process can write only one component type

  - Massive constraint, but doesn't seem to kill maintainability

* Components can be removed by *not adding* them to future state 



Past and future
---------------

* No need to lock past data (immutability)

* Future components are in per-type buffers

  - No sync needed since only one Process can write one type

* Process run order *doesn't matter*

  - All Processes read the **same past version** of any component

* Component buffers are always tightly packed

  - Again, removing a component means not *adding* to future
  - No need for garbage collection

.. XXX MINUS

* Extra per-entity overhead

  - All game state is being rewritten, all the time




Threading
---------

* **DISCLAIMER:** This stuff doesn't exist yet

* Processes can be assigned to separate threads automatically

  - Sometimes the user will need to override this (e.g. OpenGL)

* (Long-term) entities may be separated into groups

  - Each group could be processed in a separate thread


Threading - scheduling
----------------------

* Overhead between Processes and over time may vary

  - Need to move processes between threads to balance load

* Some Processes may be able to skip updates

  - E.g. rendering could dip to 30FPS, rest of the game at 60

* TBD

Threading - overhead
--------------------
.. rst-class:: build

* Component masks per entity would require locking

* Need buffers of component bits per component type

* Or bytes, bits are slow

* May as well use ints (of user-defined width)

  - MultiComponents

* A process writes future components *and component counts*

* More overhead when matching entities

  - `&` with bitmask replaced by multiple `&&`

    * Accessing multiple memory locations
    * Oh well, at least we get multiple threads


Common approach to multi-threading in games
-------------------------------------------

.. figure:: /_static/common_threading.png
  :width: 85%
  :align: center


Common approach to multi-threading in games
-------------------------------------------

* Manage threads manually
* Spawning/starting/stopping too expensive

  - Workers usually don't... work

* Design for a fixed number of cores

  - Often the lowest common denominator for multiplatform

  ========= ===============
  X360      3
  PS4/Xbone 6 (2 reserved)
  WiiU      6 (3x2 threads)
  PS3       complicated
  PSVita    3 (1 reserved)
  3DS       2
  ========= ===============


A game running in Tharsis
-------------------------

.. figure:: /_static/tharsis_threading.png
  :width: 86%
  :align: center


A game running in Tharsis
-------------------------

* A large number of Processes (10s - 100s)

* Guidelines:

  - Do one thing and do it well
  - Prefer many simple processes to few complex ones

* Multiple Processes running in each thread

* On single-core, all Processes run in one thread

  - Similar to traditional ECS

* More cores => less Processes per core => better speed

  - Process granularity limits scaling (for now)


Basic memory layout
-------------------

.. figure:: /_static/tharsis_memory.png
  :width: 95%
  :align: center

Basic memory layout
-------------------

* Past and future state (swapped between game updates)

  - Array of entity IDs

  - Arrays of components (internally raw bytes)

  - Arrays of auxiliary data (component counts)

High-level time slice
---------------------

.. figure:: /_static/tharsis_time_1.png
  :width: 95%
  :align: center


High-level time slice
---------------------

* During game update

  - Processes running in parallel threads

* Between updates

  - Only one thread is doing useful work

    * Limits max useful core count

  - Past/future state switch
  - Memory preallocation
  - Adding entities created during last update
  - Scheduling
  - ...


Process execution - time slice
------------------------------

.. figure:: /_static/tharsis_time_2.png
  :width: 95%
  :align: center


Process execution - time slice
------------------------------

* Component counts of all entities must be checked (&&-ded)

* If an entity matches

  - Process is called

    * Past state is read
    * Future state is written (even if unchanged)

  - Future component count (and maybe other data) is updated

Process execution - data read-write
-----------------------------------

.. figure:: /_static/tharsis_onthefly.png
  :width: 85%
  :align: center



Game update pseudocode - no threads
-----------------------------------

(Reminder)
^^^^^^^^^^

.. code::

   foreach(system; systems):
       ulong flags = system.componentFlags();
       uint[flags.length] componentIndices;
       componentIndices[] = 0;

       for(uint entityIndex = 0; entityIndex < entityIDs.length; entityIndex++):
           incrementComponentIndices(componentFlags[entityIndex], componentIndices);

           if(componentFlags[entityIndex] && flags):
               system.process(getComponents(componentIndices));

           increment component indices corresponding to flags

Game update pseudocode - Tharsis
--------------------------------

.. code::

   parallel_foreach(thread; threads):

       foreach(process; thread):
           uint[process.PastComponents.length] pastComponentIndices;
           componentIndices[] = 0;
           uint futureIndex = 0;

           foreach(entityIndex; 0 .. entityIDs.length):
               updatePastComponentIndices(entityIndex, pastComponentIndices);

               if(matchComponentCounts(entityIndex)):
                   futureComponent = &futureComponents(process)[futureIndex];
                   system.process(getPastComponents(componentIndices),
                                  futureComponent);

                   if(futureComponent != NULL):
                       futureComponentCounts(process)[entityIndex] = 1;
                       ++futureIndex;


Resources
---------

* Not a focus at this point, but necessary

* Loaded from descriptors

* Accessed through handles

* States 

  ========== ========== ========================
  State      Mutable    Note
  ========== ========== ========================
  New        Yes        requestLoad() => Loading
  Loading    Yes        => Loaded|LoadFailed
  Loaded     No
  LoadFailed Don't care
  ========== ========== ========================

ResourceManagers
----------------

* Manage resources (duh)

* User can't avoid manuall synchronization here

* Operations: 

  =================== ========================
  Op                  Frequency (approx)
  =================== ========================
  handle(descriptor)  <1 per update
  state(handle)       >1 per entity per update
  requestLoad(handle) 1 per entity
  resource(handle)    >1 per entity per update
  =================== ========================

* Badly designed resource managers can kill performance

* Need example thread-safe resource managers

  - Find common code, move to library


Resources - note about disposal
-------------------------------

* There's no such thing as (single) resource deletion
* Destroy everything at once
* Resource stacks may be used later


Probably not enough time for
----------------------------

* MultiComponents

* Compile-time constraints

* Code generation and API comparison with alternatives


Potential issues
----------------

* Low frequency communication between processes

  - Can be solved by components, but unwieldy
  - Need to avoid causing overhead between frames

* Spatial management

  - Most games have their own implementations

    * Need an example on how to do it with past/future

  - Need a usable (compile-time) API (more than just 3D space?)


Sources
-------

* Adam Martin.
  *Entity Systems are the future of MMOG development*
  (2007)

* Chris Stoy.
  *Game Object Component System*
  Game Programming Gems 6 (2006)

* Terrance Cohen.
  *A Dynamic Component Architecture for High Performance Gameplay*
  GDC Canada (2010)

* Tony Albrecht.
  *Pitfalls of Object Oriented Programming*
  Game Connect: Asia Pacific 2009

* Also, see the previous presentation (link below)


TODO
----

* BLOG
* Get threads to work

  - Fix bugs
* Scheduling
* Paper


Links
-----

* Entity Systems presentation: 

  https://github.com/kiith-sa/Tharsis/blob/master/meta-public/entity-systems-presentation/source/index.rst

* Code: https://github.com/kiith-sa/Tharsis
* Design: https://github.com/kiith-sa/Tharsis/blob/master/tharsis.rst
* Blog (last update forever ago): http://defenestrate.eu


Thank you
---------

* Pasta is best with the combination of

  - tuna
  - cashew nuts
  - Parmesan

    * w/ a bit of Gorgonzola or Niva if available

  - olives with anchovy filling

* But if the pasta is low quality, the result will suck, too

  - Lidl has some cheap-ish that's edible
