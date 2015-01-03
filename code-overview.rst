=============
Code overview
=============

This is an (incomplete) overview to help you find your way around the source code.

You may also want to look at the `Concepts
<http://defenestrate.eu/docs/tharsis-core/index.html#concepts>`_ articles in the main
documentation, which describe terms such as *Component*, *Process* or *Source*.

Important modules:

* `entitymanager.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/entitymanager.d>`_:

  The "core" class of Tharsis (in need of some refactoring...) where things like 
  process and entity management happen. EntityManager also calls most other subsystems
  in one way or another (scheduling, process execution, game state and so on)

* `entitypolicy.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/entitypolicy.d>`_:

  Compile-time parameters affecting Tharsis, e.g. various limits, preallocation hints,
  etc.

* `entityrange.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/entityrange.d>`_,
  `processwrapper.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/processwrapper.d>`_:

  Game state processing; including the code that executes Processes. Also direct component
  access API for users.

* `scheduler.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/scheduler.d>`_:

  Game state processing; including the code that executes Processes. Also direct component
  access API for users.

* `componentbuffer.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/componentbuffer.d>`_,
  `gamestate.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/gamestate.d>`_:

  Storage of components and entities and its inter-frame maintenance.

* `scheduler.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/scheduler.d>`_:

  Scheduling, i.e. which Process should run in which thread, and Process execution time
  estimation.

* `entityprototype.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/entityprototype.d>`_,
  `prototypemanager.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/prototypemanager.d>`_:

  Building, storing and managing data to create entities from.

* `componenttypeinfo.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/componenttypeinfo.d>`_
  `processtypeinfo.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/processtypeinfo.d>`_:

  Type information about Components (mostly run-time) and Processes (mostly compile-time)

* `componenttypemanager.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/componenttypemanager.d>`_:

  Registering coomponent types and providing access to component type info for other
  subsystems

* `entity.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/entity.d>`_,
  `entityid.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/entityid.d>`_:

  Entity itself.

* `diagnostics.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/diagnostics.d>`_:

  Used for monitoring performance, helps with benchmarking and optimization

* `descriptors.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/descriptors.d>`_,
  `resource.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/resource.d>`_,
  `resourcemanager.d <https://github.com/kiith-sa/tharsis-core/blob/master/source/tharsis/entity/resourcemanager.d>`_:

  Resource management.

Utility packages
`tharsis.util <https://github.com/kiith-sa/tharsis-core/tree/master/source/tharsis/util>`_ 
and `tharsis.std <https://github.com/kiith-sa/tharsis-core/tree/master/source/tharsis/std>`_
contain various code needed by Tharsis internals, such as some containers (hopefully to be 
replaced as Phobos improves) and extensions to standard modules like `std.traits`.


Also, code needed to use Tharsis in a sane way but not needed for the core itself can be 
found in the `tharsis-full <https://github.com/kiith-sa/tharsis-full>`_ repository.
