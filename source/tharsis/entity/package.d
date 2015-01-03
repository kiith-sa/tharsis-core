//          Copyright Ferdinand Majerech 2015.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/** Entity system itself.
 *
 * Importing this package will import the entire "core" of Tharsis, including:
 *
 * * entity management
 * * process/component type information 
 * * scheduling and execution
 * * resource management
 * * etc.
 *
 * See documentation of individual modules for details. tharsis.entity.entitymanager may
 * be a good start.
 */
module tharsis.entity;


//TODO break into subpackages when 10KLOC (total, not just code) reached
//     7139 lines as of 03.01.2015
public:
    import tharsis.entity.componenttypeinfo;
    import tharsis.entity.componenttypemanager;
    import tharsis.entity.descriptors;
    import tharsis.entity.diagnostics;
    import tharsis.entity.entity;
    import tharsis.entity.entityid;
    import tharsis.entity.entitymanager;
    import tharsis.entity.entitypolicy;
    import tharsis.entity.entityprototype;
    import tharsis.entity.entityrange;
    import tharsis.entity.lifecomponent;
    import tharsis.entity.processtypeinfo;
    import tharsis.entity.prototypemanager;
    import tharsis.entity.resource;
    import tharsis.entity.resourcemanager;
    import tharsis.entity.scheduler;
    import tharsis.entity.source;
