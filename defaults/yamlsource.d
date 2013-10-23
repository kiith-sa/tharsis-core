//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

module tharsis.defaults.yamlsource;


import dyaml.node;
import dyaml.exception;

/// A Source to load entity components from based on YAML.
struct YAMLSource
{
private:
    /// The underlying YAML node.
    dyaml.node.Node yaml_;

public:
    /// Handles loading of Sources.
    struct Loader
    {
    public:
        /// Load a Source with specified name (e.g. entity file name).
        ///
        /// (There is no requirement to load from actual files;
        /// this may be implemented by loading from some archive file or 
        /// from memory.)
        YAMLSource loadSource(string name) @trusted nothrow 
        {
            // Hack to allow nothrow to work.
            static YAMLSource implementation(string name)
            {
                import std.stdio;
                try
                {
                    return YAMLSource(dyaml.loader.Loader(name).load());
                }
                catch(YAMLException e)
                {
                    writeln(e.msg);
                    return YAMLSource(dyaml.node.Node(YAMLNull()));
                }
            }

            alias YAMLSource function(string) nothrow nothrowFunc;
            return (cast(nothrowFunc)&implementation)(name);
        }
    }

    /// If true, the Source is 'null' and doesn't store anything. 
    ///
    /// A null source may be returned when loading a Source fails, e.g. 
    /// from Loader.loadSource().
    bool isNull() @safe nothrow const { return yaml_.isNull(); }

    /// Read a value of type T to target.
    /// 
    /// Returns: true if the value was successfully read. 
    ///          false if the Source isn't convertible to specified type.
    bool readTo(T)(out T target) @trusted nothrow const
    {
        // Hack to allow nothrow to work.
        bool implementation(ref T target)
        {
            try                    { target = yaml_.as!(const T); }
            catch(NodeException e) { return false; }
            return true;
        }

        alias bool delegate(ref T target) nothrow nothrowFunc;
        return (cast(nothrowFunc)&implementation)(target); 
    }

    void opAssign(Source)(auto ref Source rhs) @safe nothrow 
        if(is(Source == YAMLSource))
    {
        yaml_ = rhs.yaml_;
    }

    /// Get a nested Source from a 'sequence' Source.
    ///
    /// (Get a value from a Source that represents an array of Sources)
    /// 
    /// Params:  index  = Index of the Source to get in the sequence.
    ///          target = Target to read the Source to.
    /// 
    /// Returns: true on success, false on failure. (e.g. if this Source is
    ///          a not a sequence, or the index is out of range).
    bool getSequenceValue(size_t index, out YAMLSource target) @trusted nothrow const
    {
        // Hack to allow nothrow to work.
        bool implementation(size_t index, ref YAMLSource target)
        {
            if(!yaml_.isSequence || index < yaml_.length) { return false; }
            try
            {
                alias ref dyaml.node.Node delegate(size_t) const constIdx;
                target = YAMLSource((cast(constIdx)&yaml_.opIndex!size_t)(index)); 
            }
            catch(NodeException e) { return false; }
            return true;
        }
        alias bool delegate(size_t, ref YAMLSource) nothrow nothrowFunc;
        return (cast(nothrowFunc)&implementation)(index, target);
    }

    /// Get a nested Source from a 'mapping' Source.
    ///
    /// (Get a value from a Source that maps strings to Sources)
    /// 
    /// Params: key    = Key identifying the nested source..
    ///         target = Target to read the nested source to.
    /// 
    /// Returns: true on success, false on failure. (e.g. if this source is
    ///          a single value instead of a mapping.)
    bool getMappingValue(string key, out YAMLSource target) @trusted nothrow const
    {
        // Hack to allow nothrow to work.
        bool implementation(string key, ref YAMLSource target)
        {
            try
            {
                alias ref dyaml.node.Node delegate(string) const constIdx;
                target = YAMLSource((cast(constIdx)&yaml_.opIndex!string)(key)); 
            }
            catch(NodeException e) { return false; }
            return true;
        }

        alias bool delegate(string, ref YAMLSource) nothrow nothrowFunc;
        return (cast(nothrowFunc)&implementation)(key, target);
    }
}
