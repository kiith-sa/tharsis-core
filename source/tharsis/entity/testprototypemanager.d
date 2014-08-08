//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Unittest for PrototypeManager.
///
/// Separate from entity/prototypemanager.d since the test depends on the
/// non-mandatory 'defaults' package.
module tharsis.entity.testprototypemanager;


import core.thread;

import std.algorithm;
import std.array;
import std.random;
import std.stdio;

import tharsis.defaults.yamlsource;
import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitypolicy;
import tharsis.entity.entitymanager;
import tharsis.entity.entityprototype;
import tharsis.entity.prototypemanager;
import tharsis.entity.resourcemanager;
import tharsis.util.testing;

unittest 
{
    struct PhysicsComponent
    {
        enum ushort ComponentTypeID = userComponentTypeID!2;

        enum minPrealloc = 16384;

        enum minPreallocPerEntity = 1.0;

        float x;
        float y;
        float z;
    }

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
    compTypeMgr.lock();
    auto entityMgr = new EntityManager!DefaultEntityPolicy(compTypeMgr);
    scope(exit) { entityMgr.destroy(); }

    PrototypeManager protoMgr;


    void thread1()
    {
        auto gen = Mt19937(unpredictableSeed);
        foreach(i; 0 .. 100) if(uniform(0.0, 1.0, gen) < 0.0015)
        {
            auto descriptor1 = EntityPrototypeResource.Descriptor(testFile1);
            auto handle1 = protoMgr.handle(descriptor1);
            if(protoMgr.state(handle1) == ResourceState.New)
            {
                protoMgr.requestLoad(handle1);
            }
            else 
            {
                auto resource = protoMgr.resource(handle1);
            }

            auto descriptor2 = EntityPrototypeResource.Descriptor(testFile2);
            auto handle2 = protoMgr.handle(descriptor2);
            assert([ResourceState.New, ResourceState.Loading, ResourceState.Loaded]
                   .canFind(protoMgr.state(handle2)));
            if(protoMgr.state(handle2) == ResourceState.Loaded)
            {
                auto resource = protoMgr.resource(handle2);
            }
        }
    }
    void thread2()
    {
        auto gen = Mt19937(unpredictableSeed);
        foreach(i; 0 .. 100) if(uniform(0.0, 1.0, gen) < 0.0015)
        {
            auto descriptor1 = EntityPrototypeResource.Descriptor(testFile1);
            auto handle1 = protoMgr.handle(descriptor1);
            assert([ResourceState.New, ResourceState.Loading, ResourceState.Loaded]
                   .canFind(protoMgr.state(handle1)));

            if(protoMgr.state(handle1) == ResourceState.Loaded)
            {
                auto resource = protoMgr.resource(handle1);

                auto descriptor2 = EntityPrototypeResource.Descriptor(testFile2);
                auto handle2 = protoMgr.handle(descriptor2);
                if(protoMgr.state(handle2) == ResourceState.New)
                {
                    protoMgr.requestLoad(handle2);
                }
            }

            auto nonexistent = "test_file_that_does_not_exist";
            auto descriptorNonexistent =
                EntityPrototypeResource.Descriptor(nonexistent);
            auto handleNonexistent = protoMgr.handle(descriptorNonexistent);
            assert([ResourceState.New, ResourceState.Loading, ResourceState.LoadFailed]
                   .canFind(protoMgr.state(handleNonexistent)));
        }
    }
    void thread3()
    {
        auto nonexistent = "test_file_that_does_not_exist";
        auto descriptorNonexistent = EntityPrototypeResource.Descriptor(nonexistent);
        auto handle = protoMgr.handle(descriptorNonexistent);
        if(protoMgr.state(handle) == ResourceState.New)
        {
            protoMgr.requestLoad(handle);
        }
    }

    // writeln("PrototypeManager unittest: repeatedly accesses and performs "
    //         "operations on resources to test thread-safety of PrototypeManager");

    foreach(game; 0 .. 10)
    {
        protoMgr = new PrototypeManager(compTypeMgr, entityMgr);
        scope(exit) { protoMgr.clear(); }

        foreach(update; 0 .. 10)
        {
            Thread[] threads;
            threads ~= new Thread(&thread1);
            threads ~= new Thread(&thread2);
            threads ~= new Thread(&thread3);
            threads[0].start();
            threads[1].start();
            threads[2].start();

            // Should work even while other threads run.
            foreach(descriptor; protoMgr.loadFailedDescriptors())
            {
                assert(descriptor.fileName == "test_file_that_does_not_exist");
            }

            foreach(thread; threads)
            {
                thread.join();
            }

            // other threads don't run when update() is called.
            protoMgr.update();
        }
    }
}
