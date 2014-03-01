//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.entity.prototypemanager;

import core.sync.rwmutex;

import std.algorithm;
import std.typecons;

import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitymanager;
import tharsis.entity.entityprototype;
import tharsis.entity.resourcemanager;
import tharsis.util.interfaces;
import tharsis.util.mallocarray;
import tharsis.util.pagedarray;
import tharsis.util.qualifierhacks;
import tharsis.util.typecons;


// TODO: Add a method to specify resources to preload at start instead of always
//       loading on demand. Try to find a generic way to do this for all or most
//       (e.g. only with StringDescriptors-files) resources/resourcemanagers.
// TODO: Try creating an universal Prototype resource and turning
//       BasePrototypeManager into PrototypeManager.
// TODO: Add an error log with info for every failed load on why it failed.

/// Base class for resource managers managing entity prototypes.
///
/// There may be various entity prototype resource types (e.g. defined in a file
/// or directly in a Source); these should be managed by separate resource
/// managers derived from BasePrototypeManager templated with the resource type.
///
/// The Resource type should define following members in addition to the
/// Descriptor type required by ResourceManager:
///
/// // Constructor from descriptor.
/// this(ref Descriptor);
/// // The prototype stored by the resource (once loaded)
/// EntityPrototype prototype;
/// // Descriptor describing this resource.
/// Descriptor descriptor;
/// // The current resource state.
/// ResourceState state;
///
/// For an example Resource type, see 
/// tharsis.entity.entityprototype.EntityPrototypeResource .
class BasePrototypeManager(Resource) : ResourceManager!Resource
{
    /// Loads a resource, setting its state to Loaded on success or LoadFailed
    /// on failure.
    ///
    /// Using a delegate allows loadResource_ to be defined in a templated
    /// constructor without templating the class with extra template parameters
    /// (avoiding e.g. templating the prototype manager with Source).
    void delegate(ref Resource) @safe nothrow loadResource_;

    /// Entity prototype resources are stored here.
    ///
    /// When a resource handle corresponding to a descriptor is first requested,
    /// an empty resource with that descriptor is added to resourcesToAdd_.
    /// Between game updates, those resources are moved to resources_. This
    /// allows us to avoid locking on every read from resources_, instead only
    /// locking resourcesToAdd_ when read/written.
    /// The state of newly added resources is ResourceState.New . Once in
    /// resources_, a resource can be modified and loaded (even asynchronously)
    /// by the prototype manager. After loading, the resource state is changed
    /// to ResourceState.Loaded if loaded successfully or
    /// ResourceState.LoadFailed if the loading failed. Once loaded, a resource
    /// is immutable and may not be modified, allowing lock-less reading from
    /// multiple threads.
    PagedArray!Resource resources_;

    /// Resources are staged here after initial creation in a handle() call with
    /// a new descriptor and until the game update ends. Then they are moved to
    /// resources_. Shared; may be written to and/or read by multiple threads.
    /// A class wrapper is used since destructors can't destroy shared struct
    /// members as of DMD 2.054.
    ///
    /// See_Also: resources_
    shared(Class!(MallocArray!Resource)) resourcesToAdd_;
    /// Mutex used to lock resourcesToAdd_.
    ReadWriteMutex resourcesToAddMutex_;

    /// Indices of prototypes requested to be loaded by the user.
    ///
    /// May contain duplicates or indices of already loaded prototypes; these
    /// will be ignored. Shared; may be written to or read by multiple threads.
    /// A class wrapper is used since destructors can't destroy shared struct
    /// members as of DMD 2.054.
    shared(Class!(MallocArray!uint)) indicesToLoad_;
    /// Mutex used to lock indicesToLoad_.
    ReadWriteMutex indicesToLoadMutex_;

    /// Memory used by loaded (immutable) entity prototypes in resources_ to
    /// store components.
    PartiallyMutablePagedBuffer prototypeData_;

public:
    /// BasePrototypeManager constructor.
    ///
    /// Params: Source               = Type of source to load prototypes from
    ///                                (e.g. YAMLSource).
    ///         Policy               = Policy used with the entity manager,
    ///                                specifying compile-time tweakables.
    ///         componentTypeManager = Component type manager where all used
    ///                                component types are registered.
    ///         entityManager        = The entity manager.
    ///         getPrototypeSource   = A delegate that takes a resource
    ///                                descriptor (of Descriptor type defined by
    ///                                the Resource type that is a template
    ///                                parameter of the prototype manager) and
    ///                                returns a Source storing an entity
    ///                                prototype. The returned source may be
    ///                                null (Source.isNull == true) if the
    ///                                source could not be loaded.
    this(Source, Policy)
        (ComponentTypeManager!(Source, Policy) componentTypeManager,
         EntityManager!Policy entityManager,
         Source delegate(ref Descriptor) nothrow getPrototypeSource)
    {
        resourcesToAdd_ = new shared(Class!(MallocArray!Resource))();
        indicesToLoad_  = new shared(Class!(MallocArray!uint))();

        // Write access should be very rare, but if it happens, give it a
        // priority to ensure it ends ASAP
        resourcesToAddMutex_ =
            new ReadWriteMutex(ReadWriteMutex.Policy.PREFER_WRITERS);
        indicesToLoadMutex_ =
            new ReadWriteMutex(ReadWriteMutex.Policy.PREFER_WRITERS);
        /// Load a component of type componentType from componentSource to
        /// prototype.
        ///
        /// Params: componentType   = Type of the component to load.
        ///         componentSource = Source to load the component from.
        ///         prototype       = Prototype to load the component into.
        ///                           Must not be locked yet.
        ///
        /// Returns: true if the component was successfully loaded,
        ///          false otherwise.
        bool loadComponent(ref const(ComponentTypeInfo) componentType,
                           ref Source componentSource,
                           ref EntityPrototype prototype) nothrow
        {
            ubyte[] storage = prototype.allocateComponent(componentType);
            if(!componentType.loadComponent(storage, componentSource,
                                            &entityManager.rawResourceHandle))
            {
                // Failed to load the component.
                return false;
            }
            return true;
        }

        /// Load components of a multicomponent type componentType from
        /// sequence to prototype.
        ///
        /// Params: componentType   = Type of components to load. Must be a
        ///                           MultiComponent type.
        ///         sequence        = Source storing a sequence of components.
        ///         prototype       = Prototype to load the components into.
        ///                           Must not be locked yet.
        ///
        /// Returns: true if the components successfully loaded,
        ///          false if either a) there are zero components (sequence is
        ///          empty, b) one or more components could not be loaded, or
        ///          c) there are more components than the maximum number of
        ///          components of type componentType in a single entity (this
        ///          limit is specified in a MultiComponent type definition).
        bool loadMultiComponent(ref const(ComponentTypeInfo) componentType,
                                ref Source sequence,
                                ref EntityPrototype prototype) nothrow
        {
            size_t count = 0;
            Source componentSource;
            while(sequence.getSequenceValue(count, componentSource))
            {
                if(!loadComponent(componentType, componentSource, prototype))
                {
                    return false;
                }
                ++count;
                if(count > componentType.maxPerEntity)
                {
                    // Too many components of this type.
                    return false;
                }
            }

            // Zero components of this type (or a non-sequence Source): loading
            // failed.
            if(count == 0)
            {
                return false;
            }
            return true;
        }

        /// Load an entity prototype resource.
        ///
        /// Params: resource = The resource to load. State of the resource will
        ///                    be set to Loaded if loaded successfully,
        ///                    LoadFailed otherwise.
        void loadResource(ref Resource resource) @trusted nothrow
        {
            auto typeMgr = componentTypeManager;
            // Get the source (e.g. YAML) storing the prototype. May fail e.g if
            // getPrototypeSource looks for the source in a nonexistent file.
            Source source = getPrototypeSource(resource.descriptor);
            if(source.isNull)
            {
                resource.state = ResourceState.LoadFailed;
                return;
            }
            // A shortcut pointer for less typing.
            EntityPrototype* prototype = &resource.prototype;
            // Provide memory to the prototype.
            ubyte[] storage =
                prototypeData_.getBytes(prototype.maxPrototypeBytes(typeMgr));
            prototype.useMemory(storage);

            const ComponentTypeInfo[] typeInfo = typeMgr.componentTypeInfo[];
            scope(exit)
            {
                assert([ResourceState.Loaded, ResourceState.LoadFailed]
                       .canFind(resource.state),
                       "Unexpected prototype resource state after loading");

                const loaded = resource.state == ResourceState.Loaded;
                // The prototype should return any memory it does not use.
                prototypeData_.lockBytes(loaded
                    ? prototype.lockAndTrimMemory(typeInfo)
                    : storage[0 .. 0]);
            }

            // Load components of the entity.
            // Look for components of all component types.
            foreach(ref type; typeInfo) if(!type.isNull)
            {
                Source compSrc;
                // No component of this type in the source.
                if(!source.getMappingValue(type.sourceName, compSrc))
                {
                    continue;
                }

                if(type.isMulti ? !loadMultiComponent(type, compSrc, *prototype)
                                : !loadComponent(type, compSrc, *prototype))
                {
                    resource.state = ResourceState.LoadFailed;
                    return;
                }
            }

            resource.state = ResourceState.Loaded;

            return;
        }

        loadResource_  = &loadResource;
        // 4 kiB won't kill us and it's likely that we won't load this many
        // new prototypes during one game update. No locking because the
        // PrototypeManager is constructed before process threads run.
        indicesToLoad_.assumeUnshared.reserve(1024);
    }

    /// Deallocate all resource arrays.
    override void clear() @trusted
    {
        // These are class objects, so they need to be destroyed manually.
        destroy(resourcesToAdd_.assumeUnshared.self_);
        destroy(indicesToLoad_.assumeUnshared.self_);
        destroy(resources_);
        destroy(prototypeData_);
    }

    // Lock-free unless requesting a handle to an unknown resource (the first
    // time a handle is requested for any given descriptor), or requesting a
    // handle to a resource that became known only during the current game
    // update.
    //
    // May be used outside of a Process, e.g. by the user when loading the first
    // entity prototype at the beginning of a game.
    override Handle handle(ref Descriptor descriptor) @trusted nothrow
    {
        // If the resource already exists, return a handle to it.
        foreach(idx; 0 .. resources_.length)
        {
            if(resources_.atConst(idx).descriptor.mapsToSameHandle(descriptor))
            {
                return Handle(cast(RawResourceHandle)idx);
            }
        }

        // Hack to make nothrow work with synchronized.
        static Handle synced(ref Descriptor descriptor,
                             BasePrototypeManager self)
        {
            auto resourcesToAdd = self.resourcesToAdd_.assumeUnshared;
            auto mutex          = self.resourcesToAddMutex_;
            // The descriptor may have been used to create a new resource
            // earlier during this game update. This should happen very rarely.
            synchronized(mutex.reader) foreach(idx; 0 .. resourcesToAdd.length)
            {
                if(resourcesToAdd[idx].descriptor.mapsToSameHandle(descriptor))
                {
                    return Handle(cast(RawResourceHandle)
                                  (self.resources_.length + idx));
                }
            }

            // New resource is being added. This should happen rarely (relative
            // to the total number of handle() calls).
            synchronized(mutex.writer)
            {
                resourcesToAdd ~= Resource(descriptor);
                // Will be at this index once contents of resourcesToAdd_ are
                // appended to resources_ when the next game update starts.
                return Handle(cast(RawResourceHandle)(self.resourceCount - 1));
            }
        }

        alias Handle function(ref Descriptor, BasePrototypeManager) nothrow
            Synced;
        return (cast(Synced)&synced)(descriptor, this);
    }

    // Always lock-free in the release build. Locks in the debug build to run
    // an assertion.
    final override ResourceState state(const Handle handle)
        @trusted pure nothrow
    {
        // Usually the handle points to a resource created before the current
        // game update.
        if(handle.rawHandle < resources_.length)
        {
            return resources_.atConst(handle.rawHandle).state;
        }

        // This can only happen with a newly added resource that's still in
        // resourcesToAdd_, meaning it's New at least until the next game update
        // starts.
        //
        // Hack to make nothrow work with synchronized.
        static void synced(Handle handle, BasePrototypeManager self) @trusted
        {
            debug synchronized(self.resourcesToAddMutex_.reader)
            {
                assert(handle.rawHandle < self.resourceCount,
                       "Resource handle out of range");
            }
        }

        alias void function(Handle, BasePrototypeManager) pure nothrow Synced;
        (cast(Synced)&synced)(handle, this);

        return ResourceState.New;
    }

    // Lock-free if the resource is already loaded. Locks otherwise.
    override void requestLoad(const Handle handle) @trusted nothrow
    {
        // If resource already loaded, loading or failed to load, do nothing.
        if(handle.rawHandle < resources_.length &&
           resources_.atConst(handle.rawHandle).state != ResourceState.New)
        {
            return;
        }

        // May or may not be loaded. Assume not loaded.
        static void synced(Handle handle, BasePrototypeManager self) @trusted
        {
            synchronized(self.indicesToLoadMutex_.writer)
            {
                self.indicesToLoad_.assumeUnshared ~= handle.rawHandle;
            }
        }
        alias void function(Handle, BasePrototypeManager) nothrow Synced;
        (cast(Synced)&synced)(handle, this);
    }

    // Lock-free.
    final override ref immutable(Resource) resource(const Handle handle)
        @trusted pure nothrow
    {
        // A resource only becomes immutable once it is loaded successfully.
        assert(state(handle) == ResourceState.Loaded,
               "Can't directly access a resource that is not loaded");

        // If loaded, a resource is in resources_.
        // (Only New resources can be in resourcesToAdd_.)
        return resources_.atImmutable(handle.rawHandle);
    }

    override Foreachable!(const(Descriptor)) loadFailedDescriptors()
    {
        class FailedDescriptors: Foreachable!(const(Descriptor))
        {
        private:
            BasePrototypeManager prototypeManager_;

        public:
            this(BasePrototypeManager prototypeManager)
            {
                prototypeManager_ = prototypeManager;
            }

            // Iterates over all resources in resources_ (which are immutable)
            // filtering down to descriptors of resources that failed to load.
            int opApply(int delegate(ref const(Descriptor)) dg)
            {
                int result = 0;
                foreach(r; 0 .. prototypeManager_.resources_.length)
                {
                    auto resource = &resources_.atConst(r);
                    if(resource.state != ResourceState.LoadFailed) { continue; }
                    result = dg(resource.descriptor);
                    if(result) { break; }
                }
                return result;
            }
        }

        return new FailedDescriptors(this);
    }

protected:
    override void update_() @trusted nothrow
    {
        // No need for synchronization here; this runs between game updates when
        // process threads don't run.

        // Need to add resources repeatedly; newly loaded resources (prototypes)
        // may contain handles adding new resources to resourcesToAdd_.
        //
        // Even if there are no newly added resources, there may be resources
        // requested to be loaded (indicesToLoad_).
        while(!resourcesToAdd_.assumeUnshared.empty ||
              !indicesToLoad_.assumeUnshared.empty)
        {
            // DMD (as of DMD 2.053) breaks the release build if we don't
            // iterate by reference here.
            // foreach(index; indicesToLoad_)
            foreach(ref resource; resourcesToAdd_.assumeUnshared)
            {
                resources_ ~= resource;
            }
            // We've loaded these now, so clear them.
            resourcesToAdd_.assumeUnshared.clear();

            // Load prototypes at indices from indicesToLoad_ (if not loaded
            // already). May add new resources to resourcesToAdd_.
            foreach(ref index; indicesToLoad_.assumeUnshared)
            {
                const resource = &resources_.atConst(index);
                if(resource.state != ResourceState.New) { continue; }

                auto resourceMutable = &resources_.atMutable(index);
                resourceMutable.state = ResourceState.Loading;
                loadResource(*resourceMutable);
                if(resourceMutable.state == ResourceState.Loaded)
                {
                    resources_.markImmutable(index);
                }
            }
            indicesToLoad_.assumeUnshared.clear();
        }
    }

private:
    /// Load specified resource.
    void loadResource(ref Resource resource) @safe nothrow
    {
        loadResource_(resource);
    }

    /// Get the total number of resources, loaded or not.
    ///
    /// Note: Reads resourcesToAdd_ which may be read/modified by multiple
    ///       threads. Any use of this method should be synchronized.
    size_t resourceCount() @trusted pure nothrow const
    {
        return resources_.length + resourcesToAdd_.assumeUnshared.length;
    }
}


/// A resource manager managing entity prototypes defined in separate files,
/// with filename descriptors.
class PrototypeManager: BasePrototypeManager!EntityPrototypeResource
{
public:
    /// Construct a PrototypeManager.
    ///
    /// Params: Source               = Type of source to load prototypes from
    ///                                (e.g. YAMLSource)
    ///         Policy               = Policy used with the entity manager,
    ///                                specifying compile-time tweakables.
    ///         componentTypeManager = Component type manager where all used
    ///                                component types are registered.
    ///         entityManager        = The entity manager.
    this(Source, Policy)
        (ComponentTypeManager!(Source, Policy) componentTypeManager,
         EntityManager!Policy entityManager)
    {
        // An EntityPrototypeResource descriptor contains the file name where
        // the prototype is defined. The prototype manager gets the prototype
        // source by loading source from that file.
        super(componentTypeManager, entityManager,
              (ref Descriptor d)
                  => componentTypeManager.loadSource(d.fileName));
    }
}
unittest
{
    PagedArray!EntityPrototypeResource testPrototypes;
}
