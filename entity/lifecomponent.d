//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/// Builtin component that specifies if an entity is 'alive'.
module tharsis.entity.lifecomponent;


/// Builtin component that specifies if an entity is 'alive' or not.
/// 
/// Entities that are not alive will not be carried over to the future.
struct LifeComponent
{
    /// Bit specifying this component type. 
    /// 
    /// The last 4 bits are reserved for builtins.
    enum ulong ComponentTypeID = 63;

    /// True if the component is alive, false otherwise.
    bool alive;
}



