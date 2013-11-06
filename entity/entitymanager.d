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
    /// Stores both past and future game states.
    ///
    /// The past_ and future_ pointers are exchanged every frame, replacing past 
    /// with future and vice versa to reuse memory,
    GameState[2] stateStorage_;

    /// Game state from the previous frame. Stores entities and their 
    /// components, including dead entities and entities that were added during 
    /// the last frame.
    immutable(GameState)* past_;

    /// Game state in the current frame. Stores entities and their components,
    /// including entities hat were added during the last frame.
    GameState* future_;

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

    /// Stores all game state (entities and components).
    ///
    /// EntityManager has two instances of GameState; past and future.
    struct GameState 
    {
        /// Stores components of all entities.
        ComponentState components;

        /// All existing entities (either past or future).
        /// 
        /// The entire length of this array is used; it doesn't have a unused 
        /// part at the end.
        Entity[] entities;
    }
    /// A range used to iterate over entities in an EntityManager and their 
    /// components. 
    /// 
    /// Used when executing process P to read past entities and their components 
    /// of types specified by InComponents, and writing future components for 
    /// the future versions of these entities.
    struct EntityRange(P, InComponents...)
    {
    private:
        // Indices of the components of the current entity in past component 
        // buffers. Only the indices of iterated component types are used.
        size_t[Policy.maxComponentTypes] componentOffsets_;

        // Index of the past entity we're currently reading.
        size_t pastEntityIndex_ = 0;

        // Index of the future entity we're currently writing to.
        size_t futureEntityIndex_ = 0;

        // Number of future components (of type P.OutComponent) written to the
        // current future entity.
        //
        // Ease bug detection with a ridiculous value
        ComponentCount futureComponentCount_ = ComponentCount.max;

        // Past entities in the entity manager.
        //
        // Past entities that are not alive are ignored.
        immutable(Entity[]) pastEntities_;

        // Future entities in the entity manager.
        //
        // Used to check if the current past entiity matches the current future 
        // entity.
        const(Entity[]) futureEntities_;

        /// Component buffer and counts for the future components written 
        /// by process P.
        ///
        /// We can't keep a typed slice as the internal buffer may get 
        /// reallocated; so we cast on every future component access.
        ComponentTypeState* futureComponents_;

        /// All processed component types.
        ///
        /// NoDuplicates! is used to avoid having two elements for the same type 
        /// if the process reads a builtin component type.
        alias NoDuplicates!(TypeTuple!(InComponents, BuiltinComponents))
            ProcessedComponents;

        /// (CTFE) Get the name of the component buffer data member for 
        /// specified component type.
        static string bufferName(C)() @trusted
        {
            return "buffer%s_".format(C.ComponentTypeID);
        }

        /// (CTFE) Get the name of the component count buffer data member for 
        /// specified component type.
        static string countsName(ushort ID)() @trusted
        {
            return "counts%s_".format(ID);
        }

        /// (CTFE) For each processed (past) component type, generate data 
        /// 2 data members: component buffer and  component count buffer.
        static string pastComponentBuffers()
        {
            string[] parts;
            foreach(index, Component; ProcessedComponents)
            {
                parts ~= q{ 
                immutable(ProcessedComponents[%s][]) %s;
                immutable(ComponentCountBuffer!Policy*) %s;
                }.format(index, bufferName!Component, 
                         countsName!(Component.ComponentTypeID));
            }
            return parts.join("\n");
        }

        /// Mixin typed slices to access all processed past components,
        /// and component count buffers to access the number of components per 
        /// entity.
        ///
        /// These are casted from the untyped buffers in the ComponentBuffer
        /// struct of each type.
        mixin(pastComponentBuffers());

        /// No default construction or copying.
        @disable this();
        @disable this(this);

    public:
        /// Construct an EntityRange to iterate over past entities of specified 
        /// entity manager.
        this(EntityManager entityManager)
        {
            pastEntities_   = entityManager.past_.entities;
            futureEntities_ = entityManager.future_.entities;
            auto past       = &entityManager.past_.components;
            // Initialize component and component count buffers for every 
            // processed past component type.
            foreach(index, Component; ProcessedComponents)
            {
                enum id  = Component.ComponentTypeID;
                // Untyped component buffer to cast to a typed slice.
                auto raw = (*past)[id].buffer.committedComponentSpace;

                mixin(q{
                %s = cast(immutable(ProcessedComponents[%s][]))raw;
                %s = &(*past)[id].counts;
                }.format(bufferName!Component, index, countsName!id));
            }

            enum futureID = P.OutComponent.ComponentTypeID;
            futureComponents_ = &entityManager.future_.components[futureID];

            // Skip dead past entities at the beginning, if any, so front() 
            // points to an alive entity (unless we're empty)
            skipDeadEntities();
        }

        /// Get the current past entity.
        Entity front() @safe pure nothrow 
        {
            return pastEntities_[pastEntityIndex_];
        }

        /// True if we've processed all alive past entities.
        bool empty() @safe pure nothrow
        {
            // Only the surviving entities are in futureEntities;
            // if we're at the last, we don't need to process the rest of the 
            // past entities; they're all dead.
            return futureEntityIndex_ >= futureEntities_.length;
        }

        /// Move to the next alive past entity (or to the end of the range if 
        /// no more alive entities left).
        /// 
        /// Also moves to the next future entity (which is the same as the next 
        /// alive past entity) and moves to the components of the next entity.
        void popFront() @trusted
        {
            assert(!empty,
                   "Trying to get the next element of an empty entity range");
            const past   = pastEntities_[pastEntityIndex_].id;
            const future = futureEntities_[futureEntityIndex_].id;
            assert(past == future,
                   "The current past entity (%s) is different from the current "
                   "future entity (%s). Maybe we didn't skip a dead past "
                   "entity, or we copied a dead entity into future entities, "
                   "or we inserted a new entity elsewhere than at the end of "
                   "future entities".format(past, future));
            assert(pastComponent!LifeComponent().alive,
                   "Current entity in EntityRange.popFront() is not alive. "
                   "Likely a bug in how skipDeadEntities is called.");

            nextFutureEntity();
            nextPastEntity();

            skipDeadEntities();
        }
        /// Get a reference to the past component of specified type in the 
        /// current entity.
        ref immutable(Component) pastComponent(Component)() @safe nothrow const
        {
            enum id = Component.ComponentTypeID;
            mixin(q{return %s[componentOffsets_[id]];}
                  .format(bufferName!Component));
        }
        /// Get a pointer to where the future component should be written for
        /// the current entity.
        P.OutComponent* futureComponent() @trusted nothrow
        {
            enum neededSpace   = maxComponentsPerEntity!(P.OutComponent);
            auto unused = futureComponents_.buffer
                          .forceUncommittedComponentSpace(neededSpace);
            return cast(P.OutComponent*)(unused.ptr);
        }

        /// Specify how many future components have been written for the current 
        /// entity.
        void setFutureComponentCount(const ComponentCount count)
            @safe pure nothrow
        {
            futureComponentCount_ = count;
        }

        /// Determine if the current entity contains components of all specified 
        /// types.
        bool matchComponents(ComponentTypeIDs...)() @trusted
        {
            enum processedIDs = componentIDs!ProcessedComponents;
            enum sortedIDs    = std.algorithm.sort([ComponentTypeIDs]);
            static assert(sortedIDs.setDifference(processedIDs).empty, 
                          "One or more matched component types are not "
                          "processed by this ComponentIterator.");

            static string matchCode()
            {
                // If the component count for any required component type is 0,
                // the result of multiplying them all is 0.
                // Af all are at least 1, the result is true.
                string[] parts;
                foreach(id; ComponentTypeIDs)
                {
                    parts ~= q{ 
                    %s.componentsInEntity(pastEntityIndex_)
                    }.format(countsName!id);
                }
                return parts.join(" * ");
            }
            mixin(q{return cast(bool)(%s);}.format(matchCode()));
        }

    private:
        /// Skip (past) dead entities until an alive entity is reached.
        void skipDeadEntities() @safe nothrow
        {
            while(!empty && !pastComponent!LifeComponent().alive) 
            {
                nextPastEntity();
            }
        }

        /// Move to the next past entity and its components.
        void nextPastEntity() @safe nothrow
        {
            // Generate code for every iterated component type to move past
            // the components in this entity.
            foreach(C; ProcessedComponents)
            {
                enum id = C.ComponentTypeID;
                mixin(q{
                componentOffsets_[id] +=
                    %s.componentsInEntity(pastEntityIndex_);
                }.format(countsName!id));
            }
            ++pastEntityIndex_;
        }

        /// Move to the next future entity.
        ///
        /// Also definitively commits the future components for the current 
        /// entity.
        void nextFutureEntity() @safe pure nothrow 
        {
            enum id = P.OutComponent.ComponentTypeID;
            futureComponents_.buffer.commitComponents(futureComponentCount_);
            futureComponents_.counts.setComponentsInEntity
                (futureEntityIndex_, futureComponentCount_);
            // Ease bug detection
            futureComponentCount_ = ComponentCount.max;
            ++futureEntityIndex_; 
        }
    }

}

