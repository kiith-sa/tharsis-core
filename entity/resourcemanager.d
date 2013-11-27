//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// API for resource management.
module tharsis.entity.resourcemanager;


import tharsis.entity.entitymanager;


/// Base class to provide unified access to resource managers.
abstract class AbstractResourceManager
{
protected:
    /// Called by EntityManager between frames. 
    /// 
    /// Can handle e.g. resource loading.
    void update_() @trusted nothrow;

package:
    /// See_Also: update()_
    final void update() @safe nothrow { update_(); }
}

/// An "untyped" resource handle, used where resource type is not known at
/// compile-time.
package alias uint RawResourceHandle;


/// Resource handle.
/// 
/// Templated by the resource type.
struct ResourceHandle(R)
{
    alias Resource = R;
package:
    /// A simple unique ID.
    RawResourceHandle resourceID_ = uint.max;

    /// Construct from a raw handle.
    this(const RawResourceHandle raw) @safe pure nothrow
    {
        resourceID_ = raw;
    }
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

public:
    /// Get a handle to resource defined with specified descriptor.
    /// 
    /// If the resource doesn't exist yet, this will create it.
    /// The resource may or may not be loaded. Use the loaded() method to 
    /// determine that.
    Handle handle(ref const Descriptor descriptor) @safe nothrow;

    /// Get the current state of the resource with specified handle.
    /// 
    /// All resources are New at the beginning, and may be requested to load 
    /// asynchronously, which means $(B no) resource is available immediately 
    /// during the first frame it exists.
    ///
    /// The resource may be Loaded at some later time, or loading may fail,
    /// resulting in a LoadFailed state.
    ResourceState state(const Handle handle) @safe pure nothrow const;

    /// Request the resource with specified handle to be loaded by the manager.
    /// 
    /// The ResourceManager will try to load the resource asynchronously.
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
    ref immutable(Resource) resource(const Handle handle) 
        @safe pure nothrow const;
}

/// Enumerates resource states.
/// 
/// See ResourceManager.state.
enum ResourceState 
{
    /// The resource has not been loaded yet.
    New,
    /// The resource has been loaded successfully and can be used.
    Loaded,
    /// The resource has failed to load and can not be used.
    LoadFailed
}
