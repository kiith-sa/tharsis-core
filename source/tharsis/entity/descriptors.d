//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Resource descriptors used by builtin resources.
///
/// These descriptors can also be used by user code, but it is recommended to
/// import tharsis.defaults.descriptors instead of this module.
module tharsis.entity.descriptors;

/** A resource descriptor represented by a single string.
 *
 * Used e.g. for resources loaded from files with file name as the descriptor.
 *
 * Params: Resource = Resource type the descriptor describes. Templating by resource type
 *                    prevents assignments between descriptors of different resource types.
 */
struct StringDescriptor(Resource)
{
    /// The string describing a resource.
    string fileName;

    /** Load a StringDescriptor from a Source such as YAML.
     *
     * Params:  source = Source to load from.
     *          result = The descriptor will be written here, if loaded succesfully.
     *
     * Returns: true if succesfully loaded, false otherwise.
     */
    static bool load(Source)(ref Source source, out StringDescriptor result)
        @safe nothrow
    {
        return source.readTo(result.fileName);
    }

    /** Determine if this descriptor maps to the same resource handle as another descriptor.
     *
     * Usually, this returns true if two descriptors describe the same resource (e.g. if
     * the descriptors are equal).
     *
     * The resource manager uses this when a resource handle is requested to decide
     * whether to load a new resource or to reuse an existing one (if a descriptor maps to
     * the same handle as a descriptor of already existing resource).
     */
    bool mapsToSameHandle(ref const(StringDescriptor) rhs) @safe pure nothrow const @nogc
    {
        return fileName == rhs.fileName;
    }
}

/** A resource descriptor storing a Source (such as YAML).
 *
 * Used when a resource is defined inline in a source file (e.g. the 'override' section of
 * a spawner component).
 *
 * Params: Resource = Resource type the descriptor describes. Templating by resource type
 *                    prevents assignments between descriptors of different resource types.
 */
struct SourceWrapperDescriptor(Resource)
{
private:
    /// Common parent class for source wrappers.
    class AbstractSourceWrapper {}

    /** Wraps a Source of a concrete type and provides access to it.
     *
     * Necessary to support any possible Source type without templating the descriptor itself.
     */
    class SourceWrapper(Source): AbstractSourceWrapper
    {
        /// Construct a SourceWrapper wrapping a source of type Source.
        this(ref Source source) @safe nothrow { this.source = source; }

        /// The wrapped source.
        Source source;
    }

    /** The wrapped source. Yes, this does use the GC (or rather, new).
     *
     * It's unlikely to cause significant overhead, since resources are shared. We may
     * wrap Sources without GC in future, but that may require tricky memory allocation.
     */
    AbstractSourceWrapper wrappedSource;

public:
    /** Access the wrapped source.
     *
     * This should be used to initialize the resource described by this descriptor.
     */
    @property ref Source source(Source)() @trusted pure nothrow
    {
        auto wrapper = cast(SourceWrapper!Source)wrappedSource;
        assert(wrapper !is null,
               "Trying to unwrap a source in a SourceWrapperDescriptor as a "
               "different source type (e.g. YAML as XML)");
        return wrapper.source;
    }

    /** Load a SourceWrapperDescriptor from a Source such as YAML.
     *
     * Used by Tharsis to initialize the descriptor.
     *
     * Params:  source = Source to load from.
     *          result = The descriptor will be written here, if loaded succesfully.
     *
     * Returns: true if succesfully loaded, false otherwise.
     */
    static bool load(Source)(ref Source source,
                             out SourceWrapperDescriptor result)
        @safe nothrow
    {
        result.wrappedSource = new SourceWrapper!Source(source);
        return true;
    }

    /** Determine if this descriptor maps to the same resource handle as another descriptor.
     *
     * Usually, this returns true if two descriptors describe one resource (e.g. if they
     * are equal). SourceWrapperDescriptors are assumed to never map to the same handle 
     * (the resource is loaded directly from a subnode of a larger resource's definition).
     *
     * The resource manager uses this when a resource handle is requested to decide
     * whether to load a new resource or to reuse an existing one (if a descriptor maps to
     * the same handle as a descriptor of already existing resource).
     */
    bool mapsToSameHandle(ref const(SourceWrapperDescriptor) rhs)
        @safe pure nothrow const @nogc
    {
        // Handles to resources using SourceWrapperDescriptors are initialized component
        // members where those resources are defined inline. I.e. they are initialized
        // together with the prototype of entities containing the component which has
        // a resource handle data member. All entities created from the same prototype
        // (usually stored in one source file) are going to have copies of an initialized
        // handle, with no need to call handle() of the resource manager. Because of this,
        // even if we assume any two SourceWrapperDescriptors (even identical) never map
        // to the same handle, the resource manager will only load a resource from one
        // descriptor once per prototype instead of loading it for every single entity.
        return false;
    }
}

/**A resource descriptor that can store either a filename to load a resource from or a
 * Source to load the resource directly.
 *
 * Used when a resource may be defined directly in a subnode of a source (e.g. YAML) file,
 * but we also want to be able to define it in a separate file and use its filename.
 *
 * Params: Resource = Resource type described by the descriptor. Templating by resource
 *                    type prevents assignments between descriptors of different resource types.
 */
struct CombinedDescriptor(Resource)
{
private:
    // Descriptor type, specifying whether the resource is described in a separate file
    // or in a Source within the descriptor.
    enum Type
    {
        // The descriptor stores a filename of a file to load the resource from.
        String,
        // The descriptor stores a Source load the resource from directly.
        SourceWrapper
    }

    // Used if type_ is String. Stores filename to load a Source from.
    StringDescriptor!Resource stringBackend_;
    // Used if type_ is SourceWrapper. Stores a Source directly.
    SourceWrapperDescriptor!Resource sourceBackend_;

    // Descriptor type.
    Type type_;

public:
    /** Construct a CombinedDescriptor describing resource in specified file.
     *
     * Params:
     *
     * fileName = Name of file to load the resource from.
     */
    this(string fileName) @safe pure nothrow @nogc
    {
        type_          = Type.String;
        stringBackend_ = StringDescriptor!Resource(fileName);
    }

    string fileName() @safe pure nothrow const @nogc
    {
        return type_ == Type.String ? stringBackend_.fileName : "<inline resource>";
    }

    /** Load a descriptor from a Source such as YAML.
     *
     * Params:  source = Source to load from.
     *          result = The descriptor will be written here, if loaded
     *                   succesfully.
     *
     * Returns: true if succesfully loaded, false otherwise.
     */
    static bool load(Source)(ref Source source, out CombinedDescriptor result)
        @safe nothrow
    {
        // Assume that a single scalar is a filename descriptor, while anything
        // not scalar is an inline source descriptor.
        if(source.isScalar)
        {
            result.type_ = Type.String;
            return StringDescriptor!Resource.load(source, result.stringBackend_);
        }
        else
        {
            result.type_ = Type.SourceWrapper;
            return SourceWrapperDescriptor!Resource.load(source, result.sourceBackend_);
        }
    }

    /** Determine if this descriptor maps to the same resource handle as another descriptor.
     *
     * Usually, this returns true if two descriptors describe the same resource
     * (e.g. if the descriptors are equal).
     *
     * The resource manager uses this when a resource handle is requested to
     * decide whether to load a new resource or to reuse an existing one
     * (if a descriptor maps to the same handle as a descriptor of already
     * existing resource).
     */
    bool mapsToSameHandle(ref const(CombinedDescriptor) rhs) @safe pure nothrow const @nogc
    {
        if(type_ != rhs.type_) { return false; }
        with(Type) final switch(type_)
        {
            case String:        return stringBackend_.mapsToSameHandle(rhs.stringBackend_);
            case SourceWrapper: return sourceBackend_.mapsToSameHandle(rhs.sourceBackend_);
        }
    }

    import tharsis.entity.componenttypemanager;
    /** Access the wrapped source.
     *
     * This should be used to initialize the resource described by this
     * descriptor.
     */
    Source source(Source)(ref Source.Loader loader) @safe nothrow
    {
        with(Type) final switch(type_)
        {
            case String:        return loader.loadSource(stringBackend_.fileName);
            case SourceWrapper: return sourceBackend_.source!Source;
        }
    }
}

// Ensure we are notified of any size increases
import tharsis.entity.entityprototype;
static assert(CombinedDescriptor!EntityPrototypeResource.sizeof <= 32,
              "CombinedDescriptor struct is unexpectedly large");

/// The default descriptor type used by builtin resource managers.
///
/// Resources using this descriptor can be loaded both from separate files and from
/// inline Source nodes (e.g. YAML mappings with YAMLSource).
template DefaultDescriptor(Resource)
{
    alias DefaultDescriptor = CombinedDescriptor!Resource;
}
