//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Utility code related to Source structs such as YAMLSource.
module tharsis.entity.source;


import std.string;
import std.traits;


/** Validate a Source at compile-time.
 *
 * Should be mixed in to types that use a Source template parameter.
 */
mixin template validateSource(Source)
{
    import std.array;
    import tharsis.util.traits;
    enum source = Source.stringof;

    static assert(__traits(hasMember, Source, "Loader"),
                  "A Source must have a Loader inner struct: " ~ source);
    alias Loader = Source.Loader;
    static assert(is(Loader == struct), "Loader of a Source must be struct: " ~ source);

    // The expected signatures of Source methods.
    Source loadSourceAPI(string name, bool logErrors) @safe nothrow { assert(false); }
    bool isNullAPI() @safe nothrow const          { unPurifier(); return false;}
    string errorLogAPI() @safe pure nothrow const { assert(false); }
    bool readToAPI(out uint target) @safe nothrow { assert(false); }
    bool getSequenceValueAPI(size_t index, out Source target) @safe nothrow { assert(false); }
    bool getMappingValueAPI(string key, out Source target) @safe nothrow { assert(false); }
    bool isScalarAPI() @safe nothrow const { unPurifier(); assert(false); }
    bool isSequenceAPI() @safe nothrow const { unPurifier(); assert(false); }
    bool isMappingAPI() @safe nothrow const { unPurifier(); assert(false); }

    // Get a string with all API errors
    enum errors = validateMethodAPI!(Loader, "loadSource",       loadSourceAPI) ~
                  validateMethodAPI!(Source, "isNull",           isNullAPI) ~
                  validateMethodAPI!(Source, "errorLog",         errorLogAPI) ~
                  validateMethodAPI!(Source, "readTo!uint",      readToAPI) ~
                  validateMethodAPI!(Source, "getSequenceValue", getSequenceValueAPI) ~
                  validateMethodAPI!(Source, "getMappingValue",  getMappingValueAPI) ~
                  validateMethodAPI!(Source, "isScalar",         isScalarAPI) ~
                  validateMethodAPI!(Source, "isSequence",       isSequenceAPI) ~
                  validateMethodAPI!(Source, "isMapping",        isMappingAPI);

    static assert(errors.empty, errors);
}
