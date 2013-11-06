//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.entity.entitymanager;


import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import std.string;
import std.traits;
import std.typetuple;
import std.typecons;
import core.sync.mutex;

import tharsis.entity.componentbuffer;
import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.defaultentitypolicy;
import tharsis.entity.entity;
import tharsis.entity.entityid;
import tharsis.entity.entityprototype;
import tharsis.entity.lifecomponent;
import tharsis.entity.processtypeinfo;
import tharsis.entity.processwrapper;
import tharsis.entity.resourcemanager;
import tharsis.util.bitmanip;
import tharsis.util.mallocarray;

}
}
/// The central, "World" object of Tharsis.
///
/// EntityManager fullfills multiple roles:
/// 
/// * Registers processes and resource managers.
/// * Creates entities from entity prototypes.
/// * Executes processes.
/// * Manages past and future entities and components.
///
/// Params: Policy = A struct with enum members specifying various compile-time 
///                  parameters and hints. See defaultentitypolicy.d for an example.
class EntityManager(Policy)
{
    mixin validateEntityPolicy!Policy;

    alias Policy.ComponentCount ComponentCount;
    /// All state belonging to one component type.
    ///
    /// Stores the components and component counts for each entity.
    ///
    /// Future versions of both the components and component counts are cleared 
    /// when the frame begins, then added over the course of a frame.
    struct ComponentTypeState
    {
    private:
        /// True if this ComponentTypeState is used by an existing component 
        /// type.
        bool enabled_;

    public:
        /// Stores components as raw bytes.
        ComponentBuffer!Policy buffer;

        /// Stores component counts for every entity (at indices matching 
        /// indices of entities in entity storage).
        ComponentCountBuffer!Policy counts;

        /// Enable the ComponentTypeState.
        ///
        /// Called when an existing component type will use this 
        /// ComponentTypeState.
        ///
        /// Params: typeInfo = Type information about the type of components 
        ///                    stored in this ComponentTypeState.
        void enable(ref const(ComponentTypeInfo) typeInfo) @safe pure nothrow
        {
            buffer.enable(typeInfo.id, typeInfo.size);
            counts.enable();
            enabled_ = true;
        }

        /// Is there a component type using this ComponentTypeState?
        bool enabled() @safe pure nothrow const { return enabled_; }

        /// Reset the buffers, clearing them.
        void reset() @safe pure nothrow
        {
            buffer.reset();
            counts.reset();
        }
    }

    /// Stores components of all entities (either past or future).
    /// 
    /// Also stores component counts of every component type for every entity.
    struct ComponentState
    {
        /// Stores component/component count buffers for all component types at 
        /// indices set by the ComponentTypeID members of the component types.
        ComponentTypeState[Policy.maxComponentTypes] self_;

        /// Access the component type state array directly.
        alias self_ this;

        /// Clear the buffers.
        ///
        /// Used to clear future component buffers when starting a frame.
        void resetBuffers()
        {
            foreach(ref data; this) if(data.enabled) { data.reset(); }
        }

        /// Inform the component counts buffers about increased (or equal) 
        /// entity count.
        /// 
        /// Called between frames when entities are added.
        void growEntityCount(const size_t count)
        {
            foreach(ref data; this) if(data.enabled) 
            {
                data.counts.growEntityCount(count);
            }
        }
    }

}

