=======
Process
=======



A Process is a 'functionality block' in Tharsis; implemented as a class with
a :ref:`process() <process-method>` method that reads :ref:`past <game-state>`
:ref:`components <component>` of one or more types and optionally writes a :ref:`future
<game-state>` component/s of a single component type.  A Process is usually used to
implement a single piece of functionality or behavior that an entity may have, such as
movement, collision, graphics, weapons, and so on. 

The Process only affects entities that have **all** past components read by the
:ref:`process() <process-method>` method.  Multiple :ref:`process() <process-method>`
methods can be used handling different component combinations, and Context_ allows to
access *all* past components of an entity at the cost of some overhead.

.. admonition:: Database Analogy

   This is somewhat similar to a SELECT in a relational database that selects components
   (columns) from only those entities (rows) that have all specified components.

   .. admonition:: Example

      ====== ========== ========== ==========
      Entity AComponent BComponent CComponent
      01     Yes        No         Yes
      02     No         Yes        Yes
      **03** **Yes**    **Yes**    **No**
      **04** **Yes**    **Yes**    **Yes**
      05     Yes        No         No
      06     No         No         Yes
      **07** **Yes**    **Yes**    **No**
      08     Yes        No         No
      ====== ========== ========== ==========

      A :ref:`process() <process-method>` method with signature 
      ``void process(ref const AComponent, ref const BComponent)`` will be called for
      entities **03**, **04** and **07**.

All Processes used must be **registered** with the EntityManager_.


-------
Example
-------

To create a Process, we first need some :ref:`components <component>` for it to process:

.. code-block:: d

   struct PositionComponent
   {
       float x = 0.0f;
       float y = 0.0f;
       enum ushort ComponentTypeID = userComponentTypeID!1;
   }
   struct DynamicComponent
   {
       float velocityX = 0.0f;
       float velocityY = 0.0f;
       enum ushort ComponentTypeID = userComponentTypeID!2;
   }

This Process will update the position of any entity that has both a ``PositionComponent``
and a ``DynamicComponent``, and keep the position of any entity that only has
a ``PositionComponent``:

.. code-block:: d

   /// Applies DynamicComponents to PositionComponents, updating entity positions.
   final class PositionProcess
   {
       /// This Process writes future PositionComponents.
       alias FutureComponent = PositionComponent;

       // Nothing to construct here.
       this() { }

       /// Update position of an entity with a dynamic component.
       void process(ref const PositionComponent posPast,
                    ref const DynamicComponent dynPast,
                    out PositionComponent posFuture) nothrow
       {
           const timeStep = 1 / 60.0;
           posFuture.x = posPast.x + timeStep * dynPast.velocityX;
           posFuture.y = posPast.y + timeStep * dynPast.velocityY;
       }

       /// Keep position of an entity that has no DynamicComponent.
       void process(ref const PositionComponent posPast, out PositionComponent posFuture) nothrow
       {
           posFuture = posPast;
       }
   }

.. TODO replace the second process() once we have a mixin to autogenerate it.

The first :ref:`process() <process-method>` method reads :ref:`past <game-state>` Position
and Dynamic components; Tharsis recognizes ``ref const`` parameters (except Context_, if
used) as past components. It uses the values of these components to write the :ref:`future
<game-state>` Position component; recognized as an ``out`` parameter.

Note the second :ref:`process() <process-method>` method; it handles entities with
a ``PositionComponent`` but no ``DynamicComponent``. Without it, no future
``PositionComponents`` would be written for these entities, effectively removing their
position.

The use of ``final``, while not necessary, may help the compiler with optimization.
Processes don't need to inherit any base class.

To actually use ``PositionProcess``, we need to register it:

.. code-block:: d

   // Register component types needed by PositionProcess
   auto compTypeMgr = new ComponentTypeManager!YAMLSource(YAMLSource.Loader());
   compTypeMgr.registerComponentTypes!(PositionComponent, DynamicComponent)();
   compTypeMgr.lock();
   auto entityMgr = new DefaultEntityManager(compTypeMgr, new Scheduler(4));

   // Construct and register the PositionProcess.
   entityMgr.registerProcess(new PositionProcess());
   // Construct and register Processes used to preserve Dynamic and Life components.
   entityMgr.registerProcess(new CopyProcess!DynamicComponent());
   entityMgr.registerProcess(new CopyProcess!LifeComponent());

Besides the ``PositionProcess``, we also register a :ref:`copy_process` for
``DynamicComponent``. This is a dummy Process that just preserves (copies into future) any
``DynamicComponents`` in entities. :ref:`life_component` is a builtin component type used
to determine when an entity should be removed (when the component is removed). Using
a :ref:`copy_process` for :ref:`life_component` effectively makes all entities immortal.

.. TODO DefaultEntityManager should be a link once we rebuild the API docs

.. note::

   The number of Processes that can be registered with an EntityManager_ is limited by its
   EntityPolicy_ parameter (with DefaultEntityPolicy_ / ``DefaultEntityManager`` this
   limit is **256**).


.. XXX more involved Process examples at the bottom of the file (with link from this example)


---------------------------
Processes and EntityManager
---------------------------

EntityManager_ only executes Processes that are registered with it using
``entityMgr.registerProcess()``. Only **one** Process can write future :ref:`components
<component>` of any single type. In the above example, there can't be a second Process
writing ``PositionComponent``.

``EntityManager`` does not *own* the registered Processes, but they must not be destroyed for
as long as the ``EntityManager`` exists. ``EntityManager`` will not destroy the Processes in its
destructor. Note that while `EntityManager.executeFrame()
<../../api/tharsis/entity/entitymanager/EntityManager.executeFrame.html>`_ is executing,
the Processes :ref:`process() <process-method>`/:ref:`preProcess()
<preProcess-method>`/:ref:`postProcess() <postProcess-method>` methods may be running in any
thread; it's not safe to access the Processes without any needed synchronization.


---------------
Process concept
---------------

This section details the methods and other members a Process can have.

A Process must be a ``class``.

^^^^^^^^^^^^^^^^^^^
Process and threads
^^^^^^^^^^^^^^^^^^^

At the beginning of each frame, Tharsis will assign each Process to run in a thread,
meaning its methods may be called from different threads between frames, but Tharsis will
never call them from different threads within a frame.

A Process can be *bound* to a specific thread at compile-time to force it to run in that
thread. See :ref:`boundToThread <boundtothread>` below.

.. _future-component:

^^^^^^^^^^^^^^^^^^^^^^^^^^
``struct FutureComponent``
^^^^^^^^^^^^^^^^^^^^^^^^^^

This member **must** be present if the :ref:`process() <process-method>` method writes any
:ref:`future <game-state>` :ref:`components <component>`.  It is used by Tharsis to verify
that all :ref:`process() <process-method>` overloads write the correct future component
type. It is usually most practical to define the component type separately and use an
alias: ``alias FutureComponent = PositionComponent``.

.. _process-method:

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
``void process(context?, >= 1 past components, future component?) nothrow``
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

This is a **required** method.

The ``process()`` method is the core of what a Process is; it reads *read-only* :ref:`past
<game-state>` components, and optionally writes future components of **one** component
type. Tharsis only calls the ``process()`` method for **matching** entities; that is
entities that contain **all** past components in its signature.


""""""""""
Parameters
""""""""""

.. _Context:

* **optional** *entity context*: ``ref const`` `EntityManager.Context
  <../../api/tharsis/entity/entitymanager/EntityManager.Context.html>`_

  Allows access to entity ID and all its past components. Note that accessing components
  through entity context has higher overhead than accessing components through
  ``process()`` parameters; it should only be done when needed (e.g. when accessing
  components of all types is needed).

.. XXX links to examples of context parameter, future multi component, etc.!

.. TODO make past multi component slices const, not immutable, and update this

* **required** 1 or more *past components*

  - ``ref const PastComponent``

    (``PastComponent`` is any component type registered with ``ComponentTypeManager``).

    Reference to a past component of an entity. Entities that do not have this component will
    not be passed to the ``process()`` method.

  - ``immutable PastMultiComponent[]``

    (``PastMultiComponent`` is any :ref:`multicomponent <multicomponent>` type
    registered with ``ComponentTypeManager``).

    Slice to past :ref:`multicomponents <multicomponent>` of an entity.  Entities that
    have zero components of this type will not be passed to the ``process()`` method.

* (**required** if the Process has a FutureComponent) *future component*:

  - ``out FutureComponent``

    (``FutureComponent`` is the :ref:`FutureComponent <future-component>` type of the
    Process)

    Reference to the future component of the entity. ``out`` default-initializes the
    component. The entity will always have the future component if this parameter pattern
    is used. See the pattern below if you need to remove a component.

  - ``ref FutureComponent*``

    (``FutureComponent`` is the :ref:`FutureComponent <future-component>` type of the Process)

    **Reference to a pointer** to the future component. If the pointer is set to null,
    no future component is written; this can be used to remove components from entities.

  - ``ref FutureMultiComponent[]``

    (``FutureMultiComponent`` is the :ref:`FutureComponent <future-component>` type of the
    Process, when it is a :ref:`multicomponent <multicomponent>` type) aa

    Reference to a slice of future :ref:`multicomponents <multicomponent>`,
    ``FutureMultiComponent.maxComponentsPerEntity`` long. After writing the future
    components the slice must be shortened to specify the number of components written.






"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
Matching different entities with multiple ``process()`` methods
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

There can be multiple ``process()`` overloads with different past component parameters
(but never a different future component). These handle the cases when an entity has
different components. E.g. in the example at the beginning of this document, one overhead
handles entities with a ``PositionComponent`` and a ``DynamicComponent``, while another
handles entities that only have a ``PositionComponent``.

Multiple ``process()`` methods may result in ambiguities; for example, if one
``process()`` overload reads past components ``A`` and ``B``, and another reads ``C`` and
``D``, Tharsis wouldn't know which ``process()`` method to call for an entity with **all**
of ``A``, ``B``, ``C`` and ``D``. Tharsis detects this as a compile-time error; to resolve
this, another overload must be added to handle entities with all the components.

.. note::

   For a Process reading many different component combinations this could quickly get out
   of hand, requiring too many ``process()`` methods. In this case it may be easier to
   directly access components through Context_.


.. _preProcess-method:

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
``void preProcess() nothrow`` | ``void preProcess(Profiler profiler) nothrow``
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

**Optional** method that will be called in each frame before processing any entities.
Useful for per-frame setup.

Can optionally have a `tharsis.prof.Profiler
<http://defenestrate.eu/docs/tharsis.prof/tharsis.prof.profiler.html>`_ parameter to get
access to a thread profiler attached to EntityManager_ through
`EntityManager.attachPerThreadProfilers()
<../../api/tharsis/entity/entitymanager/EntityManager.attachPerThreadProfilers.html>`_; if
attached by the user.

.. _postProcess-method:

^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
``void postProcess() nothrow``
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

**Optional** method that will be called in each frame after all entities have been
processed.


.. _boundtothread:

^^^^^^^^^^^^^^^^^^^^^^^^^^^
``enum uint boundToThread``
^^^^^^^^^^^^^^^^^^^^^^^^^^^

**Optional** member used to force the Process to run in a specific thread, e.g. ``enum
boundToThread = 0`` will force the Process to always run in the first thread. The actual
thread the Process will run in is ``boundToThread % threadCount`` where ``threadCount`` is
the number of threads Tharsis is using.

This is useful when the Process must absolutely always run in the same thread, e.g. when
using OpenGL. Note that binding too many Processes can effectively nullify the benefits of
Process scheduling (load balancing) in Tharsis. Still, even that may be useful for some
cases (e.g. if you really know the target machine).


.. _copy_process:

---------------
``CopyProcess``
---------------

.. TODO Link CopyProcess to tharsis-full docs once they are online

``CopyProcess(Component)`` is a template class in `Tharsis Full
<https://github.com/kiith-sa/tharsis-full>`_ that does nothing except copying :ref:`past
<game-state>` :ref:`component <component>` of specified type into the :ref:`future
<game-state>`. This is useful as a dummy Process to ensure components don't disappear when
there is no Process yet to write them.


.. _EntityManager:       ../../api/tharsis/entity/entitymanager/EntityManager.html
.. _EntityPolicy:        ../../api/tharsis/entity/entitypolicy.html
.. _DefaultEntityPolicy: ../../api/tharsis/entity/entitypolicy/DefaultEntityPolicy.html


