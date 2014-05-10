=====================================================================
A concurrent component-based entity architecture for game development
=====================================================================

:Author:
    Ferdinand Majerech
:Supervisor:
    RNDr. Jozef Jirásek, PhD.

--------
Entities
--------

* Rock, Vehicle, Event trigger, Sound source

* Can

  - Play a sound
  - Move around 
  - Trigger a script
  - Be used by the player

------------
OOP entities
------------

* Huge class trees
* Code duplication or constant refactoring
* Static types
* Overhead 
* Need programmers

.. figure:: /_static/oop0.png
  :height: 480px
  :align:  center

  https://www.orxonox.net/ticket/229

--------------------------------------
Entity component systems (RDBMS style)
--------------------------------------

* Entity is an ID associated with components (*"table row"*)
* Component is plain data (*"table column"*)
* Logic separated into *Systems* aka *Processes* (not OS processes)

  - A system specifies component types it processes (*"select"*)
  - ECS calls a system for every entity with matching components.

* Entities fully defined in data
* "Class" of a single Entity can be modified at run time
* Performant (cache locality, no virtuals)

--------------------------
Issues with existing ECS's
--------------------------

* Implicit, unexpected dependencies between processes

  - Run order: AProcess, BProcess, CProcess
  - AProcess may modify inputs of BProcess

    * BProcess writes may further affect:

      - CProcess
      - AProcess the on next game update

    * These chains get worse
    * Breakages when adding/removing/reordering systems


--------------------------
Issues with existing ECS's
--------------------------

* Manual synchronization needed for threading

  - Always difficult
  - Often not worth it due to locking overhead

=======
Tharsis
=======

-----
Goals
-----
.. rst-class:: build

* Process run order must not matter

  - May even change at runtime due to scheduling

* Automatic treading

  - Need to design to avoid locking
  - Work with varying core counts (up to ... many)
  - Schedule to evenly spread the load, avoid spikes

* Generated code to exploit Process specifics for optimization

* Byproduct: Resource management with immutable resources

=======================
Design to avoid locking
=======================

* This is mostly done
* Past and future + immutable resources


---------------
Past and future
---------------

**Past**

* State (components) from the previous game update
* Processes can read, but not write, past data

**Future**

* State created during the current game update
* Written by Processes
* A Process can only write one component type
* Components are be removed by *not adding* them to future state 

-------------------------
Past and future - results
-------------------------

* No need to lock past data (immutable)
* No need to lock future data (per-type buffers)
* Process run order doesn't matter

  - All Processes read the **same past version** of any component

* Data always tightly packed, no garbage
* All game state is being rewritten, all the time


---------
Resources
---------

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

* No destruction (OK, not really. Stacks, mass destruction)

----------------
ResourceManagers
----------------

* Operations

  =================== =============================
  Op                  Frequency (approx)
  =================== =============================
  handle(descriptor)  <1 per game update
  state(handle)       >1 per entity per game update
  requestLoad(handle) 1 per entity
  resource(handle)    >1 per entity per game update
  =================== =============================

* Can't avoid manual synchronization here

  - Use the above table as a guideline


===================
Automatic threading
===================

* This is **not** done yet, and may change

* Processes should be assigned to separate threads automatically

  - Sometimes the user will need to override this (e.g. OpenGL)


----------
Scheduling
----------

* Overhead between Processes and over time may vary

* Need to move processes between threads to balance load

  - Bin packing

    * Optimal solution probably too slow
    * TBD

-------------------------------------------
Common approach to multi-threading in games
-------------------------------------------

.. figure:: /_static/common_threading.png
  :width: 85%
  :align: center


-------------------------------------------
Common approach to multi-threading in games
-------------------------------------------

* Manual thread management
* Spawn/start/stop too expensive
* Design for a fixed (minimum) number of cores

  ========= ===============
  X360      3
  PS4/Xbone 6 (2 reserved)
  WiiU      6 (3x2 threads)
  PS3       complicated
  PSVita    3 (1 reserved)
  3DS       2
  ========= ===============


-------------------------
A game running in Tharsis
-------------------------

.. figure:: /_static/tharsis_threading.png
  :width: 86%
  :align: center


-------------------------
A game running in Tharsis
-------------------------

* Many small Processes (10s - 100s)
* Multiple Processes running in a thread
* More cores => less Processes per core => better speed


---------------------
High-level time slice
---------------------

.. figure:: /_static/tharsis_time_1.png
  :width: 95%
  :align: center


---------------------
High-level time slice
---------------------

* Game update: Processes in parallel threads

* Between updates: Only one thread is doing work

  - Past/future state switch
  - Adding entities created during last update
  - Scheduling
  - ...
  - Limits max useful core count



------------------------------
Process execution - time slice
------------------------------

.. figure:: /_static/tharsis_time_2.png
  :width: 95%
  :align: center


------------------------------
Process execution - time slice
------------------------------

* Need to match every entity
* For matching entities, there is some extra overhead

  - The rest is useful work


-----------------------------------
Process execution - data read-write
-----------------------------------

.. figure:: /_static/tharsis_onthefly.png
  :width: 85%
  :align: center


======================================
Content at the end of the presentation
======================================


----------------
Potential issues
----------------

* Low frequency communication between processes

  - Can be solved by components, but unwieldy
  - Need to avoid causing overhead between updates

* Spatial management

  - Need an example on how to do it with past/future
  - Need a usable (compile-time) API (more than just 3D space?)


-------
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

* Also, see previous presentations (below)


----
TODO
----

* BLOG
* Get threads to work

  - Fix bugs as they appear
* Scheduling
* Paper

-----
Links
-----

* Code: https://github.com/kiith-sa/Tharsis
* Design: https://github.com/kiith-sa/Tharsis/blob/master/tharsis.rst
* Blog (really needs an update): http://defenestrate.eu
* More meaty presentations: http://defenestrate.eu/2014/03/21/tharsis_presentations.html


---------
Thank you
---------
