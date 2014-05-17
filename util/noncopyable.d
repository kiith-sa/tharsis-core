//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

// A string mixin to make a struct noncopyable.
module tharsis.util.noncopyable;

/// Mixing this into a struct makes instances of that struct noncopyable.
///
/// Example:
/// --------------------
/// struct NonCopyableFloat
/// {
///     // Can't copy this struct
///     mixin(NonCopyable);
///
/// private:
///     float x_;
///
/// public:
///     float x() @safe pure nothrow const { return x_; }
/// }
/// --------------------
enum string NonCopyable =
    q{
        @disable this(typeof(this) rhs);
        @disable this(this);
        @disable void opAssign(typeof(this) rhs);
    };
