//          Copyright Ferdinand Majerech 2014.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

// General-purpose interfaces.
module tharsis.util.interfaces;


/// Any class implementing this interface supports foreach through the opApply() method.
interface Foreachable(Item)
{
public:
    /// The opApply (foreach) method to implement.
    int opApply(int delegate(ref Item) dg);
}
