//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Unittest for passing EntityAccess to process() methods..
///
/// Separate from entity/entityaccess.d since the test depends on the
/// non-mandatory 'defaults' package.
module tharsis.entity.testentityaccess;

import std.algorithm;
import std.stdio;
import std.string;

import tharsis.defaults.yamlsource;
import tharsis.defaults.copyprocess;
import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entityid;
import tharsis.entity.entitypolicy;
import tharsis.entity.entitymanager;
import tharsis.entity.entityprototype;
import tharsis.entity.lifecomponent;
import tharsis.entity.prototypemanager;
import tharsis.entity.resourcemanager;
import tharsis.util.testing;


alias Context = EntityManager!DefaultEntityPolicy.Context;

class TestEntityAccessProcess
{
public:
    alias PhysicsComponent FutureComponent;

    // The ID we expect the next processed entity to have.
    uint nextID = 0;

    void preProcess() @safe pure nothrow
    {
        nextID = 0;
    }

    void process(ref const PhysicsComponent physics,
                 out PhysicsComponent outPhysics,
                 ref const(Context) context)
    {
        outPhysics = physics;
        const entity = context.currentEntity;
        // We should have 2 entities, 0 and 1, and process them in that order
        assert(nextID < 2 && entity.id == EntityID(nextID),
               "Current entity has unexpected ID");
        ++nextID;

        foreach(idx; 0 .. 2)
        {
            const id = EntityID(idx);
            auto healthPtr  = context.pastComponent!HealthComponent(id);
            assert(healthPtr is null, "Entity with an unexpected component");


            auto physicsPtr = context.pastComponent!PhysicsComponent(id);
            assert(physicsPtr !is null, "Expected component not in entity");
            if(idx == 0)
            {
                assert(*physicsPtr == PhysicsComponent(1, 2, 3),
                       "Unexpected values in physics component of entity 0");
            }
            else if(idx == 1)
            {
                assert(*physicsPtr == PhysicsComponent(4, 2, 3),
                       "Unexpected values in physics component of entity 1");
            }
            else { assert(false); }


        }
    }

    void process(ref const PhysicsComponent physics,
                 ref const HealthComponent health,
                 out PhysicsComponent outPhysics)
    {
        outPhysics = physics;
        assert(false, "A process() method using a HealthComponent called "
                      "despite no entity using such a component");

    }
}

struct PhysicsComponent
{
    enum ushort ComponentTypeID = userComponentTypeID!2;
    enum minPrealloc = 16384;
    enum minPreallocPerEntity = 1.0;

    float x;
    float y;
    float z;
}

struct HealthComponent
{
    enum ushort ComponentTypeID = userComponentTypeID!3;
    enum minPrealloc = 16384;
    enum minPreallocPerEntity = 1.0;

    uint health;
}


unittest
{
    // Create source files to test on.
    auto testFile1 = createTempTestFile("prototype1.yaml",
                                        "physics:  \n"
                                        "    x: 1.0\n"
                                        "    y: 2.0\n"
                                        "    z: 3.0\n");
    auto testFile2 = createTempTestFile("prototype2.yaml",
                                        "physics:  \n"
                                        "    x: 4.0\n"
                                        "    y: 2.0\n"
                                        "    z: 3.0\n");
    scope(exit) { deleteTempTestFiles(); }
    assert(testFile1 !is null && testFile2 !is null,
           "Couldn't create data files (or directory) for testing");


    auto compTypeMgr = new ComponentTypeManager!YAMLSource(YAMLSource.Loader());

    compTypeMgr.registerComponentTypes!PhysicsComponent();
    compTypeMgr.registerComponentTypes!HealthComponent();
    compTypeMgr.lock();
    auto entityMgr = new EntityManager!DefaultEntityPolicy(compTypeMgr);
    scope(exit) { entityMgr.destroy(); }

    auto protoMgr = new PrototypeManager(compTypeMgr, entityMgr);
    scope(exit) { protoMgr.clear(); }

    auto process       = new TestEntityAccessProcess();
    auto lifeProcess   = new CopyProcess!LifeComponent();
    auto healthProcess = new CopyProcess!HealthComponent();

    entityMgr.registerProcess(process);
    entityMgr.registerProcess(lifeProcess);
    entityMgr.registerProcess(healthProcess);
    entityMgr.registerResourceManager(protoMgr);

    auto descriptor1 = EntityPrototypeResource.Descriptor(testFile1);
    auto descriptor2 = EntityPrototypeResource.Descriptor(testFile2);
    auto handle1     = protoMgr.handle(descriptor1);
    auto handle2     = protoMgr.handle(descriptor2);
    protoMgr.requestLoad(handle1);
    protoMgr.requestLoad(handle2);
    bool loaded1 = false;
    bool loaded2 = false;

    foreach(frame; 0 .. 8)
    {
        writeln(q{
        --------
        TESTENTITYACCESS - FRAME %s
        --------
        }.format(frame));

        entityMgr.executeFrame();
        if(protoMgr.state(handle1) == ResourceState.Loaded && !loaded1)
        {
            entityMgr.addEntity(protoMgr.resource(handle1).prototype);
            loaded1 = true;
        }
        if(protoMgr.state(handle2) == ResourceState.Loaded && !loaded2)
        {
            entityMgr.addEntity(protoMgr.resource(handle2).prototype);
            loaded2 = true;
        }
    }
}
