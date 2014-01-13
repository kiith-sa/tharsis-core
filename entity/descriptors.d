//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Resource descriptors used by builtin resources.
///
/// These descriptors can also be used by user code, but it is recommended to 
/// import tharsis.defaults.descriptors instead of this module.
module tharsis.entity.descriptors;

/// A resource descriptor represented by a single string.
///
/// Used e.g. for resources loaded from files with file name as the descriptor.
///
/// Params: Resource = The resource type the descriptor describes. Templating by 
///                    the resource type avoids accidental assignments between
///                    descriptors of different resource types.
struct StringDescriptor(Resource)
{
    /// The string describing a resource.
    string fileName;

    /// Load a StringDescriptor from a Source such as YAML.
    /// 
    /// Params:  source = Source to load from.
    ///          result = The descriptor will be written here, if loaded 
    ///                   succesfully.
    ///
    /// Returns: true if succesfully loaded, false otherwise.
    static bool load(Source)(ref Source source, out StringDescriptor result) 
        @safe nothrow
    {
        return source.readTo(result.fileName);
    }
}
