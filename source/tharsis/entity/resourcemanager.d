//          Copyright Ferdinand Majerech 2013-2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// API for resource management.
module tharsis.entity.resourcemanager;


import tharsis.entity.entitymanager;
import tharsis.util.interfaces;


/// Base class to provide unified access to resource managers.
abstract class AbstractResourceManager
{
public:
    /// Get the resource type managed by this resource manager.
    TypeInfo managedResourceType() @safe pure nothrow const;

    /** Clear the resource manager, deleting all resources.
     *
     * Must not be called while the EntityManager.executeFrame() is running.
     */
    void clear() @safe;

protected:
    /** Called by EntityManager between game updates.
     *
     * May handle e.g. resource loading. Called between game updates when the processes
     * don't run, so implementations don't need to synchronize data written by processes.
     */
    void update_() @trusted nothrow;

    /** Get a raw (untyped) handle to a resource described by a descriptor.
     *
     * Params: descriptor = An untyped pointer to the descriptor. The descriptor must be
     *                      of type Resource.Descriptor where Resource is the resource 
     *                      type managed by this resource manager.
     *
     * Returns: A raw handle to the resource (which is in the ResourceState.New state).
     */
    RawResourceHandle rawHandle_(void* descriptor) @trusted nothrow;

package:
    /// See_Also: update_()
    final void update() @safe nothrow { update_(); }

    /// See_Also: rawHandle_()
    final RawResourceHandle rawHandle(void* descriptor) @safe nothrow
    {
        return rawHandle_(descriptor);
    }
}

/// An untyped resource handle, used where resource type is not known at compile-time.
package alias uint RawResourceHandle;

/** Type of delegates used to get a resource handle without compile-time type information.
 *
 * Used when initializing handles in components to avoid passing compile-time resource
 * type parameters all over the place.
 *
 * Params: TypeInfo = Type of resource to get the handle for.
 *         void*    = A void pointer to the resource descriptor. The descriptor must be of
 *                    the Descriptor type specified in the resource type.
 *
 * Returns: A raw handle to the resource.
 */
package alias RawResourceHandle delegate(TypeInfo, void*) nothrow GetResourceHandle;

/** Resource handle.
 *
 * Templated by the resource type the handle is used for.
 */
struct ResourceHandle(R)
{
public:
    /** The resource type this handle is used with.
     *
     * Public to allow generic code to determine the resource type a handle points to.
     */
    alias Resource = R;

    /// Construct from a raw handle.
    this(const RawResourceHandle raw) @safe pure nothrow
    {
        resourceID_ = raw;
    }

    /** Get the raw resource handle.
     *
     * May be used e.g. as an index into an array of resources in a resource manager.
     */
    @property RawResourceHandle rawHandle() @safe const pure nothrow
    {
        return resourceID_;
    }

package:
    /// A simple unique ID.
    RawResourceHandle resourceID_ = uint.max;
}


/** Base class for resource managers managing a specific Resource type.
 *
 * Any Resource type must define a Descriptor type, which stores the data needed for the
 * ResourceManager to initialize the Resource (e.g. a file name).
 */
abstract class ResourceManager(Resource) : AbstractResourceManager
{
    /// Shortcut alias.
    alias ResourceHandle!Resource Handle;
    /// Ditto.
    alias Resource.Descriptor Descriptor;

protected:
    override RawResourceHandle rawHandle_(void* descriptor) @trusted nothrow
    {
        return handle(*cast(Descriptor*)descriptor).resourceID_;
    }

public:
    override TypeInfo managedResourceType() @safe pure nothrow const
    {
        return typeid(Resource);
    }

    /** Get a handle to resource defined with specified descriptor.
     *
     * If the resource doesn't exist yet, this will create it. The resource may or may not
     * be loaded. Use the loaded() method to determine that.
     */
    Handle handle(ref Descriptor descriptor) @safe nothrow;

    /** Get the current state of the resource with specified handle.
     *
     * All resources are New at the beginning, and may be requested to load asynchronously,
     * which means $(B no) resource is available immediately the first frame it exists.
     *
     * The resource may be Loaded at some later time, or loading may fail, resulting in a
     * LoadFailed state.
     *
     * This method is not const to allow for non-const internal operations (such as mutex
     * locking), but it should be logically const from the user's point of view.
     */
    ResourceState state(const Handle handle) @safe nothrow;

    /** Request the resource with specified handle to be loaded by the manager.
     *
     * The ResourceManager will try to load the resource asynchronously. If the resource
     * is already loaded, requestLoad() will do nothing.
     *
     * There is no way to force a resource to be loaded immediately; the resource may or
     * may not be loaded by the next frame; it may even fail to load.
     *
     * See_Also: state
     */
    void requestLoad(const Handle handle) @safe nothrow;

    /** Get an immutable reference to resource with specified handle.
     *
     * This can only be called if the state of the resource is ResourceState.Loaded.
     *
     * This method is not const to allow for non-const internal operations (such as mutex
     * locking), but it should be logically const from the user's point of view.
     */
    ref immutable(Resource) resource(const Handle handle) @safe nothrow;

    /** Access descriptors of all resources that failed to load.
     *
     * Used for debugging.
     */
    Foreachable!(const(Descriptor)) loadFailedDescriptors() 
        @safe pure nothrow const;

    /** Get a detailed string log of all loading errors. 
     *
     * Used for debugging.
     */
    string errorLog() @safe pure nothrow const;
}



/** Base class for resource managers storing resources in manually allocated memory.
 *
 * Resources created during a game update are temporarily stored in a mutex-protected
 * array, loaded when ResourceManager.update() is called and moved into permanent,
 * immutable storage (consisting of manually allocated pages that are never moved).
 *
 * Resources are loaded by a delegate passed to MallocResourceManager constructor.
 */
abstract class MallocResourceManager(Resource) : ResourceManager!Resource 
{
private:
    /* Loads a resource, setting its state to Loaded on success, LoadFailed on failure.
     *
     * Using a deleg allows loadResource_ to be defined in a templated ctor without adding
     * template params to the class (avoiding e.g. templating the prototype manager
     * with Source).
     */
    LoadResource loadResource_;

    import tharsis.util.pagedarray;
    /* Resources are stored here.
     *
     * When a handle for any single descriptor is first requested, an empty resource with
     * that descriptor is added to resourcesToAdd_. Between game updates, those resources
     * are moved to resources_. This allows us to avoid locking every read from resources_,
     * instead only locking resourcesToAdd_ when read/written. State of added resources is
     * ResourceState.New. Once in resources_, resource manager can load (modify) the
     * resources (even asynchronously). After loading, resource state is changed to Loaded
     * on success or LoadFailed if loading failed. Once loaded, a resource is immutable
     * and may not be modified, allowing lock-less reading from multiple threads.
     */
    PagedArray!Resource resources_;

    import core.sync.rwmutex;
    import tharsis.util.mallocarray;
    import tharsis.util.qualifierhacks;
    import tharsis.util.typecons;
    /* Resources are staged here from creation in a handle() call with a new descriptor
     * until the game update ends. Then they are moved to resources_. Shared; may be
     * written/read by multiple threads. Class wrapper is used since dtors can't destroy
     * shared struct members as of DMD 2.054.
     *
     * See_Also: resources_
     */
    shared(Class!(MallocArray!Resource)) resourcesToAdd_;
    // Mutex used to lock resourcesToAdd_.
    ReadWriteMutex resourcesToAddMutex_;

    /* Indices of resources requested to be loaded by the user.
     *
     * May contain duplicates or indices of already loaded resources; these will be
     * ignored. Shared; may be written/read by multiple threads. Class wrapper is used
     * since dtors can't destroy shared struct members as of DMD 2.054.
     */
    shared(Class!(MallocArray!uint)) indicesToLoad_;
    // Mutex used to lock indicesToLoad_.
    ReadWriteMutex indicesToLoadMutex_;

protected:
    // Any loading errors are written here.
    string errorLog_;

public:
    /// Delegate type that loads a Resource (or sets its state to LoadFailed on failure.)
    alias LoadResource = void delegate(ref Resource, ref string) @safe nothrow;

    /// Construct a MallocResourceManager using specified delegate to load resources.
    this(LoadResource loadDeleg) @trusted nothrow
    {
        resourcesToAdd_ = new shared(Class!(MallocArray!Resource))();
        indicesToLoad_  = new shared(Class!(MallocArray!uint))();

        alias PREFER_WRITERS = ReadWriteMutex.Policy.PREFER_WRITERS;
        // Write access should be very rare, but if it happens, give it a priority to
        // ensure it ends ASAP
        resourcesToAddMutex_ = new ReadWriteMutex(PREFER_WRITERS).assumeWontThrow;
        indicesToLoadMutex_  = new ReadWriteMutex(PREFER_WRITERS).assumeWontThrow;

        loadResource_ = loadDeleg;

        // 4 kiB won't kill us and it's likely that we won't load this many new resources
        // during one game update.
        indicesToLoad_.assumeUnshared.reserve(1024);
    }

    /** Deallocate all resource arrays.
     *
     * Must be called by clear() of any derived class.
     */
    override void clear() @trusted
    {
        // These are class objects, so they need to be destroyed manually.
        destroy(resourcesToAdd_.assumeUnshared.self_);
        destroy(indicesToLoad_.assumeUnshared.self_);
        destroy(resources_);
    }

    /* Lock-free unless requesting a handle to an unknown resource (first time a handle is
     * requested for any given descriptor), or requesting a handle to a resource that
     * became known only during the current game update.
     *
     * May be used outside of a Process directly by the user.
     */
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

        // The descriptor may have been used to create a new resource earlier during this
        // game update, so we need to check if it's already in resourcesToAdd. This should
        // happen very rarely.
        return
        {
            auto resourcesToAdd = resourcesToAdd_.assumeUnshared;
            auto mutex          = resourcesToAddMutex_;

            synchronized(mutex.reader) foreach(idx; 0 .. resourcesToAdd.length)
            {
                if(resourcesToAdd[idx].descriptor.mapsToSameHandle(descriptor))
                {
                    return Handle(cast(RawResourceHandle)(resources_.length + idx));
                }
            }

            // New resource is being added. This should happen rarely (relative to the
            // total number of handle() calls).
            synchronized(mutex.writer)
            {
                resourcesToAdd ~= Resource(descriptor);
                // Will be at this index once contents of resourcesToAdd_ are appended to
                // resources_ when the next game update starts.
                return Handle(cast(RawResourceHandle)(resourceCount - 1));
            }
        }().assumeWontThrow;
    }

    // Always lock-free in the release build. Locks in the debug build to run an assert.
    final override ResourceState state(const Handle handle) @trusted nothrow
    {
        const rawHandle = handle.rawHandle;
        // Usually the handle points to a resource created before the current game update,
        // which would be in resources_ by now instead of resourcesToAdd_.
        if(rawHandle < resources_.length) { return resources_.atConst(rawHandle).state; }

        // This can only happen with a newly added resource that's still in resourcesToAdd_,
        // meaning it's New at least until the next game update starts.
        delegate
        {
            synchronized(resourcesToAddMutex_.reader)
            {
                assert(rawHandle < resourceCount, "Resource handle out of range");
            }
        }().assumeWontThrow;

        return ResourceState.New;
    }

    // Lock-free if the resource is already loaded. Locks otherwise.
    override void requestLoad(const Handle handle) @trusted nothrow
    {
        const rawHandle = handle.rawHandle;
        // If resource already loaded, loading or failed to load, do nothing.
        if(rawHandle < resources_.length &&
           resources_.atConst(rawHandle).state != ResourceState.New)
        {
            return;
        }

        // May or may not be loaded. Assume not loaded.
        delegate
        {
            synchronized(indicesToLoadMutex_.writer)
            {
                indicesToLoad_.assumeUnshared ~= rawHandle;
            }
        }().assumeWontThrow;
    }

    // Lock-free.
    final override ref immutable(Resource) resource(const Handle handle) @trusted nothrow
    {
        // A resource only becomes immutable once it is loaded successfully.
        assert(state(handle) == ResourceState.Loaded,
               "Can't directly access a resource that is not loaded");

        // A Loaded resource is in resources_. (New resources are in resourcesToAdd_.)
        return resources_.atImmutable(handle.rawHandle);
    }

    override Foreachable!(const(Descriptor)) loadFailedDescriptors()
        @safe pure nothrow const
    {
        class FailedDescriptors: Foreachable!(const(Descriptor))
        {
        private:
            const(MallocResourceManager) manager_;

        public:
            this(const(MallocResourceManager) manager) @safe pure nothrow
            {
                manager_ = manager;
            }

            // Iterates over all resources in resources_ (which are immutable) filtering
            // down to descriptors of resources that failed to load.
            int opApply(int delegate(ref const(Descriptor)) dg)
            {
                int result = 0;
                foreach(r; 0 .. manager_.resources_.length)
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

    override string errorLog() @safe pure nothrow const @nogc
    {
        return errorLog_;
    }

protected:
    override void update_() @trusted nothrow
    {
        // No need for synchronization here; this runs between game updates when process
        // threads don't run.

        // Need to add resources repeatedly; newly loaded resources (e.g. prototypes) may
        // contain handles adding new resources to resourcesToAdd_.
        //
        // Even if there are no newly added resources, there may be resources requested to
        // be loaded (indicesToLoad_).
        while(!resourcesToAdd_.assumeUnshared.empty || !indicesToLoad_.assumeUnshared.empty)
        {
            foreach(ref resource; resourcesToAdd_.assumeUnshared)
            {
                resources_ ~= resource;
            }
            // We've loaded these now, so clear them.
            resourcesToAdd_.assumeUnshared.clear();

            // DMD (as of DMD 2.053) breaks the release build if we don't iterate by
            // reference here.
            // foreach(index; indicesToLoad_)

            // Load resources at indices from indicesToLoad_ (if not loaded already). May
            // add new resources to resourcesToAdd_.
            foreach(ref index; indicesToLoad_.assumeUnshared)
            {
                const resource = &resources_.atConst(index);
                if(resource.state != ResourceState.New) { continue; }

                auto resourceMutable = &resources_.atMutable(index);
                resourceMutable.state = ResourceState.Loading;
                loadResource_(*resourceMutable, errorLog_);
                if(resourceMutable.state == ResourceState.Loaded)
                {
                    resources_.markImmutable(index);
                }
            }
            indicesToLoad_.assumeUnshared.clear();
        }
    }

private:
    /* Get the total number of resources, loaded or not.
     *
     * Note: Reads resourcesToAdd_ which may be read/modified by multiple threads. Any use
     *       of this method should be synchronized.
     */
    size_t resourceCount() @trusted pure nothrow const
    {
        return resources_.length + resourcesToAdd_.assumeUnshared.length;
    }
}


/** Enumerates resource states.
 *
 * See ResourceManager.state.
 */
enum ResourceState
{
    /// The resource has not been loaded yet.
    New,
    /// The resource is currently being loaded.
    Loading,
    /// The resource has been loaded successfully and can be used.
    Loaded,
    /// The resource has failed to load and can not be used.
    LoadFailed
}
