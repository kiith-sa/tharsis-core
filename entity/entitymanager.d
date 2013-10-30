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
}

