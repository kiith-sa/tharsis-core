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

    /// Determine if this descriptor maps to the same resource handle as another
    /// descriptor.
    ///
    /// Usually, this returns true if two descriptors describe the same resource
    /// (e.g. if the descriptors are equal). SourceWrapperDescriptors are 
    /// assumed to never map to the same handle (the resource is loaded 
    /// directly from a source fragment of a larger resource's definition). 
    /// 
    /// The resource manager uses this when a resource handle is requested to
    /// decide whether to load a new resource or to reuse an existing one
    /// (if a descriptor maps to the same handle as a descriptor of already
    /// existing resource).
    bool mapsToSameHandle(ref const(SourceWrapperDescriptor) rhs)
        @safe pure nothrow const
    {
        // Handles to resources using SourceWrapperDescriptors are initialized
        // as members of components where those resources are defined inline.
        // That is, they are initialized together with the entity prototype of
        // the entities containing the component which has the resource handle
        // as a data member. Therefore, all entities created from the same
        // prototype (usually corresponding to one source file) are going to
        // have copies of an already initialized handle, with no need to call
        // handle() of the resource manager managing the resource.  Because of
        // this, even if we assume any two SourceWrapperDescriptors (even
        // identical) never map to the same handle, the resource manager will
        // only load a resource from one descriptor once (per prototype) instead
        // of loading it for every single entity.
        return false;
    } 
}
