.. _source:

======
Source
======

.. TODO Entity, EntityPrototype, ComponentTypeManager, YAMLSource etc. should be hyperlinks

A *Source* represents 'source code' to load an ``Entity`` (``EntityPrototype``) from. It
is passed to ``ComponentTypeManager`` as a template parameter. **Tharsis-full** provides
``YAMLSource``, a *Source* implementation based on the `YAML <http://yaml.org>`_ format.
A *Source* type should be a struct with :ref:`interface <source-skeleton>` described below.


------------------------------
Constraints of a Source struct
------------------------------

Size of a *Source* can be at most ``tharsis.entity.componenttypemanager.maxSourceBytes``
(``512`` right now). A *Source* must be copyable; if it stores nested data (e.g.
JSON/XML/YAML subnodes), copying a *Source* must either copy this nested data or share it
by using e.g. reference counted or GC storage.


.. _source-skeleton:

---------------------------
Skeleton of a Source struct
---------------------------

.. code-block:: d

   // Note: some manual casting might be needed to ensure that methods of a Source type
   // have required attributes (such as pure, nothrow, etc.).
   //
   // This can be done by ensuring that the method obeys the attribute (e.g. ensuring that
   // all exceptions are caught) and manually casting functions that don't have the attribute.
   //
   // For example:
   //
   // (cast(void delegate(int, int) @safe nothrow)&methodThatDoesNotThrow)()
   struct Source
   {
   public:
       /// Handles loading of Sources.
       struct Loader
       {
       public:
           /** Load a Source with specified name (e.g. entity file name).
            *
            *
            * Params: name      = Name to identify the source by (e.g. a file name).
            *         logErrors = If true, errors generated during the use of the Source
            *                     (such as loading errors, conversion errors etc.) should
            *                      be logged, accessible through errorLog().
            *
            * There is no requirement to load from actual files; this may be implemented
            * by loading from some archive file or from memory.
            */
           TestSource loadSource(string name, bool logErrors) @safe nothrow
           {
               assert(false);
           }
       }

       /** If true, the Source is 'null' and doesn't store anything.
        *
        * A null Source may be returned when loading a Source with Loader.loadSource() fails.
        */
       bool isNull() @safe nothrow const
       {
           assert(false);
       }

       /** If logging is enabled, returns errors logged during construction and use
        * of this Source. Otherwise returns a warning message.
        */
       string errorLog() @safe pure nothrow const
       {
           assert(false);
       }

       /** Read a value of type T to target.
        *
        * Returns: true if the value was successfully read.
        *          false if the Source isn't convertible to specified type.
        */
       bool readTo(T)(out T target) @safe nothrow
       {
           assert(false);
       }

       /** Get a nested Source from a 'sequence' Source.
        *
        * (Get a value from a Source that represents an array of Sources)
        *
        * Can only be called on if the Source is a sequence (see isSequence()).
        *
        * Params:  index  = Index of the Source to get in the sequence.
        *          target = Target to read the Source to.
        *
        * Returns: true on success, false if index is out of range.
        */
       bool getSequenceValue(size_t index, out TestSource target) @safe nothrow
       {
           assert(false);
       }


       /** Get a nested Source from a 'mapping' Source.
        *
        * (Get a value from a Source that maps strings to Sources)
        *
        * Can only be called on if the Source is a mapping (see isMapping()).
        *
        * Params: key    = Key identifying the nested source..
        *         target = Target to read the nested source to.
        *
        * Returns: true on success, false if there is no such key in the mapping.
        */
       bool getMappingValue(string key, out TestSource target) @safe nothrow
       {
           assert(false);
       }

       /// Is this a scalar source? A scalar is any source that is not a sequence or a mapping.
       bool isScalar() @safe nothrow const
       {
           assert(false);
       }

       /// Is this a sequence source? A sequence acts as an array of values of various types.
       bool isSequence() @safe nothrow const
       {
           return yaml_.isSequence();
       }

       /// Is this a mapping source? A mapping acts as an associative array of various types.
       bool isMapping() @safe nothrow const
       {
           return yaml_.isMapping();
       }
   }

---------------------------------------
Format of components in a Source struct
---------------------------------------

A *Source* storing an entity must be a mapping where keys are lower-case component type
names without the *"Component"* suffix. The values corresponding to these keys must be
mappings containing the component's properties, or sequences of such mappings for multi
components. Example in YAML:

.. code-block:: yaml

   visual:
       r: 255
       g: 0
       b: 0
       a: 255
   engine:
       acceleration: 90.0
       maxSpeed:     450.0
   timedTriggerMulti:
       - time:      0.3
         triggerID: 1
         periodic: true
       - time:      0.3
         triggerID: 2
         periodic: true

This YAML fragment encodes an entity with (fictional) ``VisualComponent``,
``EngineComponent`` and 2 ``TimedTriggerMultiComponents``.

If not all properties are specified for a component, default values of these properties
(as specified in the body of the component type) are used.

For example, to load an int property ``awesomeness`` of an ``ExampleComponent``, Tharsis
will use the *Source* API roughly in the following way:

.. code-block:: d

   bool getAwesomeness(ref const(Source) components, out int awesomeness)
   {
       if(components.isNull())
       {
           // Components is null
           return false;
       }
       Source exampleComponent;
       if(!component.getMappingValue("example", exampleComponent))
       {
           // Could not find ExampleComponent in components
           return false;
       }
       Source awesomenessSource;
       if(!exampleComponent.getMappingValue("awesomeness", awesomenessSource))
       {
           // Could not find awesomeness in exampleComponent source
           static if(ExampleComponent.awesomeness is a resource handle)
           {
               return false;
           }
           else
           {
               awesomeness = ExampleComponent.awesomeness.init;
               return true;
           }
       }
       if(!awesomenessSource.readTo(awesomeness))
       {
           // awesomeness could not be read to int
           return false;
       }
       return true;
   }
