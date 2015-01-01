//          Copyright Ferdinand Majerech 2015.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.entity.resource;


/** Enumerates resource states.
 *
 * See_also: ResourceManager.state
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

/** Template for simple creation of Resource types for usage with ResourceManager classes.
 *
 * Adds members required to be in a Resource type (the Descriptor alias) as well as
 * members that are useful in almost every resource (descriptor itself, resource state).
 *
 * Params:
 *
 * Payload = The "resource" itself, that is, the data we need to manage as a resource.
 *
 *
 * Example:
 * --------------------
 * /// Our resource - data describing a weapon, but can also have e.g. enum or alias members.
 * struct Weapon
 * {
 *     /// Maximum number of projectiles a weapon can spawn in a single burst.
 *     enum maxProjectiles = 128;
 *
 *     /// Time between successive bursts of projectiles.
 *     float burstPeriod;
 *
 *     import tharsis.defaults.components;
 *     /// Spawner components to spawn projectiles in a burst.
 *     SpawnerMultiComponent[] projectiles;
 * }
 *
 * import tharsis.entity.resource;
 * /// Weapon resource itself. Embeds Weapon.
 * alias WeaponResource = DefaultResource!Weapon;
 * --------------------
 */
struct DefaultResource(Payload)
{
    import tharsis.entity.descriptors;
    /// Uses DefaultDescriptor.
    alias Descriptor = DefaultDescriptor!(typeof(this));

    /// Stored resource data.
    Payload payload_;

    /// Current state of the resource.
    ResourceState state = ResourceState.New;

    /// Descriptor of the weapon (file name or a `Source <../concepts/source.html>`_).
    Descriptor descriptor;

    /// Use the members of the payload as members of this resource.
    alias payload_ this;


    /// No default construction.
    @disable this();

    /// Construct a new (not loaded) DefaultResource with specified descriptor.
    this(ref Descriptor descriptor) @safe pure nothrow @nogc
    {
        this.descriptor = descriptor;
    }
}
