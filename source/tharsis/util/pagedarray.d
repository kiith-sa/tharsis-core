//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// Containers with an array-like API implemented in terms of pages.
///
/// Pointers to objects of value types stored in these arrays will always stay
/// valid as the pages are never moved in memory; when a paged array runs out of
/// space it allocates a new pages. Elements within pages are tightly packed to
/// increase cache locality.
///
/// Also provide the ability to marks some elements as immutable once they are 
/// fully initialized, while other elements, awaiting initialization, are 
/// mutable.
module tharsis.util.pagedarray;


import core.memory;
import std.array;
import std.traits;
import std.typecons;

import tharsis.util.alloc;
import tharsis.util.noncopyable;


/// A paged array storing value-type items which can be initialized and then
/// marked immutable.
///
/// Items can be appended using '~=' and are never moved in memory. By default,
/// items are mutable and can be accessed by atMutable() and atConst().
/// A call to markImmutable() marks an item immutable, after which it can only
/// be accessed by atConst() and atImmutable().
///
/// This allows to add and initialize an item before marking it definitively
/// immutable.
///
/// That said, PagedArray allocates its items manually, and all items regardless
/// of their mutability are destroyed when the PagedArray is destroyed.
///
/// Currently, PagedArray doesn't support structs with elaborate desctructors;
/// that may be added in future if at all useful with immutable objects.
struct PagedArray(T)
    if(!hasElaborateDestructor!T && (is(T == struct) || isScalarType(T)))
{
    /// Flags specifying mutability of each item (more flags may be added later if needed).
    struct ItemFlags 
    {
        /// Is this item mutable?
        bool mutable = true;

        /// Use individual bits if we more flags needed, don't waste memory.
        static assert(ItemFlags.sizeof == 1);
    }

private:
    /// The number of bytes at the end of each page used to store item flags
    /// (e.g. if the corresponding item is mutable or not).
    enum pageItemFlagsBytes = (base_.PageSize / T.sizeof) * ItemFlags.sizeof;

    /// The number of items stored in one page.
    enum pageCapacity       = (base_.PageSize - pageItemFlagsBytes) / T.sizeof;

    /// The number of bytes taken by items stored in one page.
    enum pageItemBytes      = pageCapacity * T.sizeof;

    /// Handles page allocation.
    ///
    /// Every page stores not only the items, but also flags specifying e.g.
    /// whether each item is mutable or not.
    ///
    /// In page 'page', stored items take page[0 .. pageItemBytes],
    /// and their flags take page[$ - pageItemFlagsBytes .. $].
    ///
    /// Members are manually delegated instead of using alias this because of
    /// DMD issues (as of DMD 2.053).
    PagedArrayBase base_;

    /// Shortcut aliases.
    alias PagedArrayBase.Page Page;
    alias PagedArrayBase.PageSize PageSize;

    /// Access the pages as if they were a direct data member.
    ref inout(Page*[]) pages_() inout { return base_.pages_; }

    /// Add a new page with type info about the stored type for debugging.
    void addPage(TypeInfo typeInfo) @trusted nothrow 
    {
        base_.addPage(typeInfo); 
    }

    /// The number of items stored in the array.
    uint length_;

public:
    /// No direct copying; we don't want the indirection of a reference type and
    /// we almost certainly never want to copy by value.
    @disable void opAssign(T[] array);
    mixin(NonCopyable);

    /// Destroy the array, destroying all stored items.
    ///
    /// This *will* destroy the items marked as immutable; any references to 
    /// items in the paged array must not be used after the array is destroyed.
    @trusted nothrow ~this()
    {
        // True if the GC needs to scan T.
        if(typeid(T).flags) foreach(ref p; base_.pages_)
        {
            GC.removeRange(cast(void*)p); 
        }
        clear();
        // base_.~this also gets called here.
    }

    /// Access the mutable item at specified index.
    ///
    /// Can only be called if the item at specified index has not been marked
    /// immutable.
    ref T atMutable(const size_t index)
        @safe pure nothrow
    {
        assert(index < length, "PagedArray[] index out of range");
        const pageIndex   = index / pageCapacity;
        const inPageIndex = index % pageCapacity;

        assert(pageItemFlags(pages_[pageIndex])[inPageIndex].mutable, 
               "Trying to get a mutable reference to a PagedArray element "
               "that has been marked immutable");

        return pageItems(pages_[pageIndex])[inPageIndex];
    }

    /// Access the item at specified index using a const reference.
    ///
    /// Works with both mutable and immutable index.
    ref const(T) atConst(const size_t index)
        @safe pure nothrow const
    {
        // Can be mutable or immutable; doesn't matter
        assert(index < length, "PagedArray[] index out of range");
        const pageIndex   = index / pageCapacity;
        const inPageIndex = index % pageCapacity;
        return pageItems(pages_[pageIndex])[inPageIndex];
    }

    /// Mark the item at specified index as immutable.
    ///
    /// After this is called, any previously created non-const references to the
    /// item must not be used.
    void markImmutable(const size_t index) 
        @safe pure nothrow
    {
        // Can be mutable or immutable; doesn't matter
        assert(index < length, "PagedArray[] index out of range");
        const pageIndex   = index / pageCapacity;
        const inPageIndex = index % pageCapacity;
        pageItemFlags(pages_[pageIndex])[inPageIndex].mutable = false;
    }

    /// Access the immutable item at specified index.
    ///
    /// Can only be called if the item at specified index has been marked 
    /// immutable.
    ref immutable(T) atImmutable(const size_t index)
        @trusted pure nothrow const
    {
        // Can be mutable or immutable; doesn't matter
        assert(index < length, "PagedArray[] index out of range");
        const pageIndex   = index / pageCapacity;
        const inPageIndex = index % pageCapacity;

        // Accessing an item as immutable makes it immutable permanently from
        // that point on.
        const(PagedArrayBase.Page)* page = pages_[pageIndex];

        assert(!pageItemFlags(page)[inPageIndex].mutable, 
               "Trying to get an immutable reference to a PagedArray element "
               "that has not yet been marked immutable");
        return *cast(immutable(T)*)(&pageItems(page)[inPageIndex]);
    }

    /// Add a new item to the end of the array.
    ///
    /// The item will be considered mutable until marked immutable.
    void opCatAssign(U : T)(auto ref U element) @trusted nothrow
        if(isImplicitlyConvertible!(T, U))
    {
        const oldLength = this.length;
        // If we run out of space, add a new page.
        if(capacity == oldLength) 
        {
            addPage(typeid(T)); 
            // True if the GC needs to scan T.
            if(typeid(T).flags)
            {
                auto page = base_.pages_.back;
                GC.addRange(cast(void*)(*page).ptr, PageSize); 
            }
        }

        const pageIndex   = oldLength / pageCapacity;
        const inPageIndex = oldLength % pageCapacity;
        base_.Page* page  = pages_[pageIndex];

        pageItems(page)[inPageIndex]     = element;
        // Default ItemFlags (i.e. mutable).
        pageItemFlags(page)[inPageIndex] = ItemFlags();
        ++length_;
    }

    /// Add a new item to the end of the array and mark it immutable.
    void appendImmutable(U : T)(auto ref U element) @safe nothrow
        if(isImplicitlyConvertible!(T, U))
    {
        this.opCatAssign(element);
        markImmutable(length - 1);
    }

    /// Get the number of items stored in the array.
    @property size_t length() @safe const pure nothrow {return length_;}

private:
    /// Destroy all objects in the array and set its size to zero.
    ///
    /// Allows reuse of allocated space after the stored objects are no longer
    /// needed.
    ///
    /// This *will* destroy the items marked as immutable; any references to 
    /// items in the paged array must not be used after this is called.
    void clear() @trusted pure nothrow
    {
        foreach(ref page; pages_) { (*page)[] = 0; }
        length_ = 0;
    }

    /// Get the number of items can we store without allocating a new page.
    @property size_t capacity() @safe const pure nothrow 
    {
        return pageCapacity * pages_.length;
    }

    /// Access the part of specified page containing items.
    ///
    /// Each page in a PagedArray stores the items at the beginning,
    /// and flags specifying mutability of those items at the end.
    inout(T)[] pageItems(inout(PagedArrayBase.Page)* page) 
        @trusted inout nothrow
    {
        return cast(inout(T)[])((*page)[0 .. pageItemBytes]);
    }

    /// Get a slice of flags (mutability, etc.) of items in a page.
    ///
    /// The last pageItemFlagsBytes of a page store these flags.
    inout(ItemFlags)[] pageItemFlags(inout(PagedArrayBase.Page)* page) 
        @trusted inout nothrow
    {
        return cast(inout(ItemFlags)[])((*page)[$ - pageItemFlagsBytes .. $]);
    }
}


/// A paged array capable of 'building' and storing immutable data.
///
/// To write to the buffer, the getBytes() method can be used to access a slice
/// of the buffer. After writing to this slice, it must be 'locked' by the 
/// lockBytes() method; this marks the area pointed to by the slice immutable.
/// Any further getBytes() calls will access area after the locked data, 
/// allocating new pages as needed.
struct PartiallyMutablePagedBuffer 
{
private:
    /// Handles page allocation.
    PagedArrayBase base_;

    /// Allow direct access to pages, as with a base class.
    alias base_ this;

    /// The number of immutable bytes in the buffer.
    ///
    /// Equal to PageSize * (immutable pages) + (immutable bytes in this page)
    uint immutableSize_;

    /// Size of the slice returned by the last call to getBytes().
    ///
    /// I.e. the number of bytes the user can modify at the moment.
    uint bytesAwaitingLock_;

public:
    /// No direct copying; we don't want the indirection of a reference type and
    /// we almost certainly never want to copy by value.
    @disable void opAssign(PartiallyMutablePagedBuffer);
    @disable this(this);

    /// Gets a slice of all remaining bytes in the current page.
    ///
    /// If the current page is full, adds a new page and returns its bytes.
    ///
    /// Note: The slice must be locked by lockBytes() before another call to
    ///       getBytes().
    ubyte[] getBytes() @trusted nothrow
    {
        assert(bytesAwaitingLock_ == 0, 
               "getBytes() called without locking bytes from previous "
               "getBytes() call");
        const pageIndex   = immutableSize_ / PageSize;
        const inPageIndex = immutableSize_ % PageSize;

        if(pageIndex >= pages_.length) { addPage(typeid(ubyte)); }

        bytesAwaitingLock_ = cast(uint)(PageSize - inPageIndex);
        return (*pages_[pageIndex])[inPageIndex .. $];
    }

    /// Gets a slice of at least specified size.
    ///
    /// If the current page doesn't have enough bytes, adds a new page and
    /// returns a slice to it.
    ///
    /// Params: minBytes = Minimum size of the returned slice in bytes.
    ///
    /// Note: The slice must be locked by lockBytes() before another call to
    ///       getBytes().
    ubyte[] getBytes(const size_t minBytes) @safe nothrow
    {
        assert(minBytes <= PageSize,
               "Trying to get more bytes than page size. "
               "Maybe the max entity size is too large (greater than 1MB) ? "
               "Consider this a Tharsis bug that needs to be fixed.");
        auto result = getBytes();
        if(result.length < minBytes)
        {
            // Locks the remainder of the current page, forcing the next 
            // getBytes() call to allocate a new page.
            lockBytes(result);
            result = getBytes();
            // The first getBytes() might have had too few bytes until the end 
            // of the current page; the second _must_ have an entire page, and
            // minBytes is asserted to fit into a single page.
            assert(result.length >= minBytes,
                   "Second getBytes didn't get enough bytes");
        }
        return result;
    }

    /// Lock (mark as immutable) a slice returned by getBytes().
    ///
    /// After writing data, this can be used to mark that data immutable.
    /// If not the entire slice was used, it is enough to lock the used part,
    /// as long as it starts at the beginning of the slice returned by 
    /// getBytes(); However, the remainder of the slice may not be used
    /// afterwards; a new call to getBytes() must be used.
    /// 
    /// Params: bytes = The slice of bytes to mark as immutable.
    ///                 Must be a slice returned by a previous call to 
    ///                 getBytes(), or a prefix of such slice.
    ///
    /// After a call of lockBytes(), the locked area may only be read, never 
    /// written, and the unused part (if any) of the slice returned by the 
    /// previous getBytes() call may not be used in any way.
    void lockBytes(const(ubyte[]) bytes) @trusted pure nothrow
    {
        assert(bytesAwaitingLock_ != 0, 
               "lockBytes() called without calling getBytes() first");
        assert(bytes.length <= bytesAwaitingLock_, 
               "Trying to lock more bytes than returned by getBytes() call");

        bytesAwaitingLock_ = 0;

        const pageIndex   = immutableSize_ / PageSize;
        const inPageIndex = immutableSize_ % PageSize;
        assert(bytes.ptr == (*pages_[pageIndex]).ptr + inPageIndex,
               "Slice passed to lockBytes() doesn't match the slice returned "
               "by the most recent getBytes()");

        immutableSize_ += bytes.length;
    }

    /// Clear the buffer, zeroing out all data (but not deallocating).
    ///
    /// Should $(B only) be used when there are no slices/references into the 
    /// buffer; destroys all data, including data marked immutable.
    ///
    /// Useful for reuse of a buffer once all its contents are obsolete.
    void clear() @trusted pure nothrow
    {
        assert(bytesAwaitingLock_ == 0, 
               "Calling clear() between getBytes()/lockBytes()");

        foreach(ref page; pages_) { (*page)[] = 0; }
        immutableSize_ = 0;
    }
}
unittest 
{
    enum mega = 1024 * 1024;

    PartiallyMutablePagedBuffer buffer;

    buffer.lockBytes(buffer.getBytes(1)[0 .. 1]);
    assert(buffer.immutableSize_ == 1 && buffer.pages_.length == 1);

    // Need to allocate a new page to get a whole mega of bytes.
    buffer.lockBytes(buffer.getBytes(mega)[0 .. mega]);
    assert(buffer.immutableSize_ == 2 * mega && buffer.pages_.length == 2);

    // All of these should work without allocating new pages.
    buffer.lockBytes(buffer.getBytes(mega)[0 .. 2]);
    assert(buffer.immutableSize_ == 2 * mega + 2 && buffer.pages_.length == 3);
    buffer.lockBytes(buffer.getBytes(mega - 2)[0 .. 5]);
    assert(buffer.immutableSize_ == 2 * mega + 7 && buffer.pages_.length == 3);
    buffer.lockBytes(buffer.getBytes(mega - 7)[0 .. mega - 7]);
    assert(buffer.immutableSize_ == 3 * mega && buffer.pages_.length == 3);
}



/// A basic, untyped paged array.
///
/// Used as a base for other paged array types. Stores raw bytes.
///
/// Note: Page size is currently fixed - this may cause problems if larger 
///       allocations are needed.
struct PagedArrayBase
{
private:
    /// Fixed page size. 
    ///
    /// This limits the maximum size of slices allocated from paged arrays;
    /// if we need arbitrarily long slices we might need to allow page size 
    /// to vary between instances or even between pages.
    enum PageSize = 1024 * 1024;

    //TODO (future) try to align to memory pages (or hugepages) - if useful.
    /// A single page. Currently just a fixed size buffer of bytes.
    alias ubyte[PageSize] Page;

    /// An array of pointers to allocated pages.
    Page*[] pages_ = null;

    /// No direct copying of; we don't want the indirection of a reference type
    /// and we almost certainly never want to copy by value.
    @disable void opAssign(PagedArrayBase);
    @disable this(this);

    /// Destroy the array, freeing all pages.
    @trusted nothrow ~this()
    {
        if(pages_ is null) { return; }
        // [0 .. 1] means delete one page
        foreach(ref p; pages_) { freeMemory(cast(void[])p[0 .. 1]); }
        pages_[] = null;
        freeMemory(cast(void[])pages_);
        pages_ = null;
    }

    /// Add a new page.
    ///
    /// Params: typeInfo = If the page is used to store data of a particular
    ///                    type, its type information can be passed to be used
    ///                    for debugging. This *does not* mark allocated memory
    ///                    as a range for GC scanning! If the GC must scan 
    ///                    the data in the page, the caller must add it as a GC
    ///                    range.
    void addPage(TypeInfo typeInfo) @trusted nothrow 
    {
        auto oldPages = pages_;
        // New size of pages_ in bytes. We just add a single page.
        // We always reallocate pages_; we may eventually need to avoid that.
        const bytes = (Page*).sizeof * (pages_.length + 1);
        pages_ = cast(Page*[])(allocateMemory(bytes, typeInfo)[0 .. bytes]);
        pages_[0 .. oldPages.length] = oldPages[];
        foreach(ref p; pages_[oldPages.length .. $])
        {
            p = cast(Page*)allocateMemory(PageSize, typeInfo).ptr;
        }
        if(oldPages is null) { return; }
        freeMemory(cast(void[])oldPages);
    }
}

