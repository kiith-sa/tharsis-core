//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Resource descriptors built into Tharsis.
module tharsis.defaults.descriptors;

public import tharsis.entity.descriptors;


/// A resource descriptor storing a Source (such as YAML).
///
/// Used when a resource is defined inline in a source file
/// (e.g. the 'override' section of a spawner component).
///
/// Params: Resource = The resource type the descriptor describes. Templating by 
///                    the resource type avoids accidental assignments between
///                    descriptors of different resource types.
struct SourceWrapperDescriptor(Resource)
{
private:
    /// Common parent class for source wrappers.
    class AbstractSourceWrapper {}

    /// Wraps a Source of a concrete type and provides access to it.
    ///
    /// Necessary to support any possible Source type without templating
    /// the descriptor itself.
    class SourceWrapper(Source): AbstractSourceWrapper
    {
        /// Construct a SourceWrapper wrapping a source of type Source.
        this(ref Source source) @safe nothrow { this.source = source; }

        /// The wrapped source.
        Source source;
    }

    /// The wrapped source. Yes, this does use the GC (or rather, new).
    ///
    /// It's unlikely to cause significant overhead, however, since resources 
    /// are shared. We may wrap Sources without using the GC in future,
    /// but this may require tricky memory allocation.
    AbstractSourceWrapper wrappedSource;

public:
    /// Access the wrapped source.
    ///
    /// This should be used to initialize the resource described by this
    /// descriptor.
    @property ref Source source(Source)() @trusted pure nothrow 
    {
        auto wrapper = cast(SourceWrapper!Source)wrappedSource;
        assert(wrapper !is null, 
               "Trying to unwrap a source in a SourceWrapperDescriptor as a "
               "different source type (e.g. YAML as XML)");
        return wrapper.source;
    }

    /// Load a SourceWrapperDescriptor from a Source such as YAML.
    ///
    /// Used by Tharsis to initialize the descriptor.
    /// 
    /// Params:  source = Source to load from.
    ///          result = The descriptor will be written here, if loaded 
    ///                   succesfully.
    ///
    /// Returns: true if succesfully loaded, false otherwise.
    static bool load(Source)(ref Source source, 
                             out SourceWrapperDescriptor result) 
        @safe nothrow
    {
        result.wrappedSource = new SourceWrapper!Source(source);
        return true;
    }
}
