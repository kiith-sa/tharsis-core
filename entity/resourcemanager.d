//          Copyright Ferdinand Majerech 2013.
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

    /// Clear the resource manager, deleting all resources.
    ///
    /// Must not be called while the EntityManager where the resource manager
    /// is registered runs.
    void clear() @safe;

protected:
    /// Called by EntityManager between game updates.
    ///
    /// Can handle e.g. resource loading.
    /// Called between game updates when the processes don't run, so
    /// implementations don't need to synchronize data written to by processes.
    void update_() @trusted nothrow;

    /// Get a raw (untyped) handle to a resource described by a descriptor.
    ///
    /// Params: descriptor = An untyped pointer to the descriptor. The 
    ///                      descriptor must be of type Resource.Descriptor 
    ///                      where Resource is the resource type managed by this 
    ///                      resource manager.
    /// 
    /// Returns: A raw handle to the resource (which is in the ResourceState.New
    ///          state).
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

/// An "untyped" resource handle, used where resource type is not known at
/// compile-time.
package alias uint RawResourceHandle;

/// A type of delegates used to get a resource handles without compile-time
/// type information.
/// 
/// Used when initializing handles in components to avoid passing compile-time 
/// resource type parameters all over the place.
///
/// Params: TypeInfo = Type of resource to get the handle for.
///         void*    = A void pointer to the resource descriptor.
///                    The descriptor must be of the Descriptor type specified 
///                    in the resource type.
///
/// Returns: A raw handle to the resource.
package alias RawResourceHandle delegate(TypeInfo, void*) nothrow 
        GetResourceHandle;

/// Resource handle.
/// 
/// Templated by the resource type.
struct ResourceHandle(R)
{
public:
    /// The resource type this handle is used with.
    ///
    /// Public to allow generic code to determine the resource type a handle 
    /// points to.
    alias Resource = R;

    /// Construct from a raw handle.
    this(const RawResourceHandle raw) @safe pure nothrow
    {
        resourceID_ = raw;
    }

    /// Get the raw resource handle.
    ///
    /// May be used e.g. as an index into an array of resources in a resource 
    /// manager.
    @property RawResourceHandle rawHandle() @safe const pure nothrow 
    {
        return resourceID_;
    }

package:
    /// A simple unique ID.
    RawResourceHandle resourceID_ = uint.max;
}


/// Base class for resource managers managing a specific Resource type.
///
/// Any Resource type must define a Descriptor type, which stores the data 
/// needed for the ResourceManager to initialize the Resource (e.g. a file 
/// name).
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

    /// Get a handle to resource defined with specified descriptor.
    /// 
    /// If the resource doesn't exist yet, this will create it.
    /// The resource may or may not be loaded. Use the loaded() method to 
    /// determine that.
    Handle handle(ref Descriptor descriptor) @safe nothrow;

    /// Get the current state of the resource with specified handle.
    /// 
    /// All resources are New at the beginning, and may be requested to load 
    /// asynchronously, which means $(B no) resource is available immediately 
    /// during the first frame it exists.
    ///
    /// The resource may be Loaded at some later time, or loading may fail,
    /// resulting in a LoadFailed state.
    ///
    /// This method is not const to allow for non-const internal operations
    /// (such as mutex locking), but it should be logically const from the
    /// user's point of view.
    ResourceState state(const Handle handle) @safe pure nothrow;

    /// Request the resource with specified handle to be loaded by the manager.
    ///
    /// The ResourceManager will try to load the resource asynchronously.
    /// If the resource is already loaded, requestLoad() will do nothing.
    ///
    /// There is no way to force a resource to be loaded immediately; the
    /// resource may or may not be loaded by the next frame; it may even fail
    /// to load.
    ///
    /// See_Also: state
    void requestLoad(const Handle handle) @safe nothrow;

    /// Get an immutable reference to resource with specified handle.
    ///
    /// This can only be called if the state of the resource is
    /// ResourceState.Loaded.
    ///
    /// This method is not const to allow for non-const internal operations
    /// (such as mutex locking), but it should be logically const from the
    /// user's point of view.
    ref immutable(Resource) resource(const Handle handle) @safe pure nothrow;

    /// Access descriptors of all resources that failed to load.
    ///
    /// Used for debugging.
    Foreachable!(const(Descriptor)) loadFailedDescriptors();
}


/// Enumerates resource states.
/// 
/// See ResourceManager.state.
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
