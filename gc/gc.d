/**
 * Contains the garbage collector implementation.
 *
 * Copyright: Copyright Digital Mars 2001 - 2013.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Walter Bright, David Friedman, Sean Kelly
 */

/*          Copyright Digital Mars 2005 - 2013.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module gc.gc;

// D Programming Language Garbage Collector implementation

/************** Debugging ***************************/

//debug = PRINTF;               // turn on printf's
//debug = COLLECT_PRINTF;       // turn on printf's
//debug = LOGGING;              // log allocations / frees
//debug = MEMSTOMP;             // stomp on memory
//debug = SENTINEL;             // add underrun/overrrun protection
//debug = PTRCHECK;             // more pointer checking
//debug = PTRCHECK2;            // thorough but slow pointer checking
//debug = PROFILING;            // measure performance of various steps.

/*************** Configuration *********************/

version = STACKGROWSDOWN;       // growing the stack means subtracting from the stack pointer
                                // (use for Intel X86 CPUs)
                                // else growing the stack means adding to the stack pointer

/***************************************************/

import gc.bits;
import gc.stats;
import gc.os;

import cstdlib = core.stdc.stdlib : calloc, free, malloc, realloc;
import core.stdc.string;
import core.bitop;
import core.sync.mutex;
static import core.memory;
private alias BlkAttr = core.memory.GC.BlkAttr;

version (GNU) import gcc.builtins;

debug (PRINTF) import core.stdc.stdio : printf;
debug (COLLECT_PRINTF) import core.stdc.stdio : printf;
debug private import core.stdc.stdio;

debug(PRINTF) void printFreeInfo(Pool* pool)
{
    uint nReallyFree;
    foreach(i; 0..pool.npages) {
        if(pool.pagetable[i] >= B_FREE) nReallyFree++;
    }

    printf("Pool %p:  %d really free, %d supposedly free\n", pool, nReallyFree, pool.freepages);
}

debug(PROFILING)
{
    // Track total time spent preparing for GC,
    // marking, sweeping and recovering pages.
    import core.stdc.stdio, core.stdc.time;
    __gshared long prepTime;
    __gshared long markTime;
    __gshared long sweepTime;
    __gshared long recoverTime;
}

private
{
    enum USE_CACHE = true;

    // The maximum number of recursions of mark() before transitioning to
    // multiple heap traversals to avoid consuming O(D) stack space where
    // D is the depth of the heap graph.
    enum MAX_MARK_RECURSIONS = 64;
}
    struct BlkInfo
    {
        void*  base;
        size_t size;
        uint   attr;
    }
private
{
    extern (C) void rt_finalize2(void* p, bool det, bool resetMemory);

    extern (C) void thread_suspendAll();
    extern (C) void thread_resumeAll();

    // core.thread
    enum IsMarked : int
    {
        no,
        yes,
        unknown, // memory is not managed by GC
    }
    alias IsMarked delegate(void*) IsMarkedDg;
    extern (C) void thread_processGCMarks(scope IsMarkedDg isMarked);

    alias void delegate(void*, void*) scanFn;
    extern (C) void thread_scanAll(scope scanFn fn);

    extern (C) void onOutOfMemoryError() @trusted /* pure dmd @@@BUG11461@@@ */ nothrow;
    extern (C) void onInvalidMemoryOperationError() @trusted /* pure dmd @@@BUG11461@@@ */ nothrow;

    enum
    {
        OPFAIL = ~cast(size_t)0
    }
}


alias GC gc_t;


/* ======================= Leak Detector =========================== */


debug (LOGGING)
{
    struct Log
    {
        void*  p;
        size_t size;
        size_t line;
        char*  file;
        void*  parent;

        void print()
        {
            printf("    p = %p, size = %zd, parent = %p ", p, size, parent);
            if (file)
            {
                printf("%s(%u)", file, line);
            }
            printf("\n");
        }
    }


    struct LogArray
    {
        size_t dim;
        size_t allocdim;
        Log *data;

        void Dtor()
        {
            if (data)
                cstdlib.free(data);
            data = null;
        }

        void reserve(size_t nentries)
        {
            assert(dim <= allocdim);
            if (allocdim - dim < nentries)
            {
                allocdim = (dim + nentries) * 2;
                assert(dim + nentries <= allocdim);
                if (!data)
                {
                    data = cast(Log*)cstdlib.malloc(allocdim * Log.sizeof);
                    if (!data && allocdim)
                        onOutOfMemoryError();
                }
                else
                {   Log *newdata;

                    newdata = cast(Log*)cstdlib.malloc(allocdim * Log.sizeof);
                    if (!newdata && allocdim)
                        onOutOfMemoryError();
                    memcpy(newdata, data, dim * Log.sizeof);
                    cstdlib.free(data);
                    data = newdata;
                }
            }
        }


        void push(Log log)
        {
            reserve(1);
            data[dim++] = log;
        }

        void remove(size_t i)
        {
            memmove(data + i, data + i + 1, (dim - i) * Log.sizeof);
            dim--;
        }


        size_t find(void *p)
        {
            for (size_t i = 0; i < dim; i++)
            {
                if (data[i].p == p)
                    return i;
            }
            return OPFAIL; // not found
        }


        void copy(LogArray *from)
        {
            reserve(from.dim - dim);
            assert(from.dim <= allocdim);
            memcpy(data, from.data, from.dim * Log.sizeof);
            dim = from.dim;
        }
    }
}


/* ============================ GC =============================== */


const uint GCVERSION = 1;       // increment every time we change interface
                                // to GC.

// This just makes Mutex final to de-virtualize member function calls.
final class GCMutex : Mutex {}

class GC
{
    // For passing to debug code (not thread safe)
    __gshared size_t line;
    __gshared char*  file;

    uint gcversion = GCVERSION;

    Gcx *gcx;                   // implementation

    // We can't allocate a Mutex on the GC heap because we are the GC.
    // Store it in the static data segment instead.
    __gshared GCMutex gcLock;    // global lock
    __gshared byte[__traits(classInstanceSize, GCMutex)] mutexStorage;

    void initialize()
    {
        mutexStorage[] = typeid(GCMutex).init[];
        gcLock = cast(GCMutex) mutexStorage.ptr;
        gcLock.__ctor();
        gcx = cast(Gcx*)cstdlib.calloc(1, Gcx.sizeof);
        if (!gcx)
            onOutOfMemoryError();
        gcx.initialize();
    }


    void Dtor()
    {
        version (linux)
        {
            //debug(PRINTF) printf("Thread %x ", pthread_self());
            //debug(PRINTF) printf("GC.Dtor()\n");
        }

        if (gcx)
        {
            gcx.Dtor();
            cstdlib.free(gcx);
            gcx = null;
        }
    }


    /**
     *
     */
    void enable()
    {
        gcLock.lock();
        scope(exit) gcLock.unlock();
        assert(gcx.disabled > 0);
        gcx.disabled--;
    }


    /**
     *
     */
    void disable()
    {
        gcLock.lock();
        scope(exit) gcLock.unlock();
        gcx.disabled++;
    }


    /**
     *
     */
    uint getAttr(void* p)
    {
        if (!p)
        {
            return 0;
        }

        uint go()
        {
            Pool* pool = gcx.findPool(p);
            uint  oldb = 0;

            if (pool)
            {
                auto biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

                oldb = gcx.getBits(pool, biti);
            }
            return oldb;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        return go();
    }


    /**
     *
     */
    uint setAttr(void* p, uint mask)
    {
        if (!p)
        {
            return 0;
        }

        uint go()
        {
            Pool* pool = gcx.findPool(p);
            uint  oldb = 0;

            if (pool)
            {
                auto biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

                oldb = gcx.getBits(pool, biti);
                gcx.setBits(pool, biti, mask);
            }
            return oldb;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        return go();
    }


    /**
     *
     */
    uint clrAttr(void* p, uint mask)
    {
        if (!p)
        {
            return 0;
        }

        uint go()
        {
            Pool* pool = gcx.findPool(p);
            uint  oldb = 0;

            if (pool)
            {
                auto biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

                oldb = gcx.getBits(pool, biti);
                gcx.clrBits(pool, biti, mask);
            }
            return oldb;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        return go();
    }


    /**
     *
     */
    void *malloc(size_t size, uint bits = 0, size_t *alloc_size = null)
    {
        if (!size)
        {
            if(alloc_size)
                *alloc_size = 0;
            return null;
        }

        void* p = void;
        size_t localAllocSize = void;
        if(alloc_size is null) alloc_size = &localAllocSize;

        // Since a finalizer could launch a new thread, we always need to lock
        // when collecting.  The safest way to do this is to simply always lock
        // when allocating.
        {
            gcLock.lock();
            scope(exit) gcLock.unlock();
            p = mallocNoSync(size, bits, alloc_size);
        }

        if (!(bits & BlkAttr.NO_SCAN))
        {
            memset(p + size, 0, *alloc_size - size);
        }

        return p;
    }


    //
    //
    //
    private void *mallocNoSync(size_t size, uint bits = 0, size_t *alloc_size = null)
    {
        assert(size != 0);

        void *p = null;
        Bins bin;

        //debug(PRINTF) printf("GC::malloc(size = %d, gcx = %p)\n", size, gcx);
        assert(gcx);
        //debug(PRINTF) printf("gcx.self = %x, pthread_self() = %x\n", gcx.self, pthread_self());

        if (gcx.running)
            onInvalidMemoryOperationError();

        size += SENTINEL_EXTRA;
        bin = gcx.findBin(size);
        Pool *pool;

        if (bin < B_PAGE)
        {
            if(alloc_size)
                *alloc_size = binsize[bin];
            int  state     = gcx.disabled ? 1 : 0;
            bool collected = false;

            while (!gcx.bucket[bin] && !gcx.allocPage(bin))
            {
                switch (state)
                {
                case 0:
                    auto freedpages = gcx.fullcollect();
                    collected = true;
                    if (freedpages < gcx.npools * ((POOLSIZE / PAGESIZE) / 8))
                    {   /* Didn't free much, so try allocating more anyway.
                         * Note: freedpages is not the amount of memory freed, it's the amount
                         * of full pages freed. Perhaps this should instead be the amount of
                         * memory freed.
                         */
                        gcx.newPool(1,false);
                        state = 2;
                    }
                    else
                        state = 1;
                    continue;
                case 1:
                    gcx.newPool(1, false);
                    state = 2;
                    continue;
                case 2:
                    if (collected)
                        onOutOfMemoryError();
                    state = 0;
                    continue;
                default:
                    assert(false);
                }
            }
            p = gcx.bucket[bin];

            // Return next item from free list
            gcx.bucket[bin] = (cast(List*)p).next;
            pool = (cast(List*)p).pool;
            //debug(PRINTF) printf("\tmalloc => %p\n", p);
            debug (MEMSTOMP) memset(p, 0xF0, size);
        }
        else
        {
            p = gcx.bigAlloc(size, &pool, alloc_size);
            if (!p)
                onOutOfMemoryError();
        }
        size -= SENTINEL_EXTRA;
        p = sentinel_add(p);
        sentinel_init(p, size);
        gcx.log_malloc(p, size);

        if (bits)
        {
            gcx.setBits(pool, cast(size_t)(p - pool.baseAddr) >> pool.shiftBy, bits);
        }
        return p;
    }


    /**
     *
     */
    void *calloc(size_t size, uint bits = 0, size_t *alloc_size = null)
    {
        if (!size)
        {
            if(alloc_size)
                *alloc_size = 0;
            return null;
        }

        size_t localAllocSize = void;
        void* p = void;
        if(alloc_size is null) alloc_size = &localAllocSize;

        // Since a finalizer could launch a new thread, we always need to lock
        // when collecting.  The safest way to do this is to simply always lock
        // when allocating.
        {
            gcLock.lock();
            scope(exit) gcLock.unlock();
            p = mallocNoSync(size, bits, alloc_size);
        }

        memset(p, 0, size);
        if (!(bits & BlkAttr.NO_SCAN))
        {
            memset(p + size, 0, *alloc_size - size);
        }

        return p;
    }

    /**
     *
     */
    void *realloc(void *p, size_t size, uint bits = 0, size_t *alloc_size = null)
    {
        size_t localAllocSize = void;
        auto oldp = p;
        if(alloc_size is null) alloc_size = &localAllocSize;

        // Since a finalizer could launch a new thread, we always need to lock
        // when collecting.  The safest way to do this is to simply always lock
        // when allocating.
        {
            gcLock.lock();
            scope(exit) gcLock.unlock();
            p = reallocNoSync(p, size, bits, alloc_size);
        }

        if (p !is oldp && !(bits & BlkAttr.NO_SCAN))
        {
            memset(p + size, 0, *alloc_size - size);
        }

        return p;
    }


    //
    //
    //
    private void *reallocNoSync(void *p, size_t size, uint bits = 0, size_t *alloc_size = null)
    {
        if (gcx.running)
            onInvalidMemoryOperationError();

        if (!size)
        {   if (p)
            {   freeNoSync(p);
                p = null;
            }
            if(alloc_size)
                *alloc_size = 0;
        }
        else if (!p)
        {
            p = mallocNoSync(size, bits, alloc_size);
        }
        else
        {   void *p2;
            size_t psize;

            //debug(PRINTF) printf("GC::realloc(p = %p, size = %zu)\n", p, size);
            version (SENTINEL)
            {
                sentinel_Invariant(p);
                psize = *sentinel_size(p);
                if (psize != size)
                {
                    if (psize)
                    {
                        Pool *pool = gcx.findPool(p);

                        if (pool)
                        {
                            auto biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

                            if (bits)
                            {
                                gcx.clrBits(pool, biti, ~BlkAttr.NONE);
                                gcx.setBits(pool, biti, bits);
                            }
                            else
                            {
                                bits = gcx.getBits(pool, biti);
                            }
                        }
                    }
                    p2 = mallocNoSync(size, bits, alloc_size);
                    if (psize < size)
                        size = psize;
                    //debug(PRINTF) printf("\tcopying %d bytes\n",size);
                    memcpy(p2, p, size);
                    p = p2;
                }
            }
            else
            {
                psize = gcx.findSize(p);        // find allocated size
                if (psize >= PAGESIZE && size >= PAGESIZE)
                {
                    auto psz = psize / PAGESIZE;
                    auto newsz = (size + PAGESIZE - 1) / PAGESIZE;
                    if (newsz == psz)
                        return p;

                    auto pool = gcx.findPool(p);
                    auto pagenum = (p - pool.baseAddr) / PAGESIZE;

                    if (newsz < psz)
                    {   // Shrink in place
                        debug (MEMSTOMP) memset(p + size, 0xF2, psize - size);
                        pool.freePages(pagenum + newsz, psz - newsz);
                    }
                    else if (pagenum + newsz <= pool.npages)
                    {   // Attempt to expand in place
                        foreach (binsz; pool.pagetable[pagenum + psz .. pagenum + newsz])
                            if (binsz != B_FREE) goto Lfallthrough;

                        debug (MEMSTOMP) memset(p + psize, 0xF0, size - psize);
                        debug(PRINTF) printFreeInfo(pool);
                        memset(&pool.pagetable[pagenum + psz], B_PAGEPLUS, newsz - psz);
                        pool.freepages -= (newsz - psz);
                        debug(PRINTF) printFreeInfo(pool);
                    }
                    pool.updateOffsets(pagenum);
                    if (bits)
                    {
                        immutable biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;
                        gcx.clrBits(pool, biti, ~BlkAttr.NONE);
                        gcx.setBits(pool, biti, bits);
                    }
                    if(alloc_size)
                        *alloc_size = newsz * PAGESIZE;
                    gcx.updateCaches(p, newsz * PAGESIZE);
                    return p;
                    Lfallthrough:
                        {}
                }
                if (psize < size ||             // if new size is bigger
                    psize > size * 2)           // or less than half
                {
                    if (psize)
                    {
                        Pool *pool = gcx.findPool(p);

                        if (pool)
                        {
                            auto biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

                            if (bits)
                            {
                                gcx.clrBits(pool, biti, ~BlkAttr.NONE);
                                gcx.setBits(pool, biti, bits);
                            }
                            else
                            {
                                bits = gcx.getBits(pool, biti);
                            }
                        }
                    }
                    p2 = mallocNoSync(size, bits, alloc_size);
                    if (psize < size)
                        size = psize;
                    //debug(PRINTF) printf("\tcopying %d bytes\n",size);
                    memcpy(p2, p, size);
                    p = p2;
                }
                else if(alloc_size)
                    *alloc_size = psize;
            }
        }
        return p;
    }


    /**
     * Attempt to in-place enlarge the memory block pointed to by p by at least
     * minbytes beyond its current capacity, up to a maximum of maxsize.  This
     * does not attempt to move the memory block (like realloc() does).
     *
     * Returns:
     *  0 if could not extend p,
     *  total size of entire memory block if successful.
     */
    size_t extend(void* p, size_t minsize, size_t maxsize)
    {
        gcLock.lock();
        scope(exit) gcLock.unlock();
        return extendNoSync(p, minsize, maxsize);
    }


    //
    //
    //
    private size_t extendNoSync(void* p, size_t minsize, size_t maxsize)
    in
    {
        assert(minsize <= maxsize);
    }
    body
    {
        if (gcx.running)
            onInvalidMemoryOperationError();

        //debug(PRINTF) printf("GC::extend(p = %p, minsize = %zu, maxsize = %zu)\n", p, minsize, maxsize);
        version (SENTINEL)
        {
            return 0;
        }
        auto psize = gcx.findSize(p);   // find allocated size
        if (psize < PAGESIZE)
            return 0;                   // cannot extend buckets

        auto psz = psize / PAGESIZE;
        auto minsz = (minsize + PAGESIZE - 1) / PAGESIZE;
        auto maxsz = (maxsize + PAGESIZE - 1) / PAGESIZE;

        auto pool = gcx.findPool(p);
        auto pagenum = (p - pool.baseAddr) / PAGESIZE;

        size_t sz;
        for (sz = 0; sz < maxsz; sz++)
        {
            auto i = pagenum + psz + sz;
            if (i == pool.npages)
                break;
            if (pool.pagetable[i] != B_FREE)
            {   if (sz < minsz)
                    return 0;
                break;
            }
        }
        if (sz < minsz)
            return 0;
        debug (MEMSTOMP) memset(p + psize, 0xF0, (psz + sz) * PAGESIZE - psize);
        memset(pool.pagetable + pagenum + psz, B_PAGEPLUS, sz);
        pool.updateOffsets(pagenum);
        pool.freepages -= sz;
        gcx.updateCaches(p, (psz + sz) * PAGESIZE);
        return (psz + sz) * PAGESIZE;
    }


    /**
     *
     */
    size_t reserve(size_t size)
    {
        if (!size)
        {
            return 0;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        return reserveNoSync(size);
    }


    //
    //
    //
    private size_t reserveNoSync(size_t size)
    {
        assert(size != 0);
        assert(gcx);

        if (gcx.running)
            onInvalidMemoryOperationError();

        return gcx.reserve(size);
    }


    /**
     *
     */
    void free(void *p)
    {
        if (!p)
        {
            return;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        return freeNoSync(p);
    }


    //
    //
    //
    private void freeNoSync(void *p)
    {
        debug(PRINTF) printf("Freeing %p\n", cast(size_t) p);
        assert (p);

        if (gcx.running)
            onInvalidMemoryOperationError();

        Pool*  pool;
        size_t pagenum;
        Bins   bin;
        size_t biti;

        // Find which page it is in
        pool = gcx.findPool(p);
        if (!pool)                              // if not one of ours
            return;                             // ignore
        sentinel_Invariant(p);
        p = sentinel_sub(p);
        pagenum = cast(size_t)(p - pool.baseAddr) / PAGESIZE;

        debug(PRINTF) printf("pool base = %p, PAGENUM = %d of %d, bin = %d\n", pool.baseAddr, pagenum, pool.npages, pool.pagetable[pagenum]);
        debug(PRINTF) if(pool.isLargeObject) printf("Block size = %d\n", pool.bPageOffsets[pagenum]);
        biti = cast(size_t)(p - pool.baseAddr) >> pool.shiftBy;

        gcx.clrBits(pool, biti, ~BlkAttr.NONE);

        bin = cast(Bins)pool.pagetable[pagenum];
        if (bin == B_PAGE)              // if large alloc
        {   size_t npages;

            // Free pages
            npages = pool.bPageOffsets[pagenum];
            debug (MEMSTOMP) memset(p, 0xF2, npages * PAGESIZE);
            pool.freePages(pagenum, npages);
        }
        else
        {   // Add to free list
            List *list = cast(List*)p;

            debug (MEMSTOMP) memset(p, 0xF2, binsize[bin]);

            list.next = gcx.bucket[bin];
            list.pool = pool;
            gcx.bucket[bin] = list;
        }
        gcx.log_free(sentinel_add(p));
    }


    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    void* addrOf(void *p)
    {
        if (!p)
        {
            return null;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        return addrOfNoSync(p);
    }


    //
    //
    //
    void* addrOfNoSync(void *p)
    {
        if (!p)
        {
            return null;
        }

        return gcx.findBase(p);
    }


    /**
     * Determine the allocated size of pointer p.  If p is an interior pointer
     * or not a gc allocated pointer, return 0.
     */
    size_t sizeOf(void *p)
    {
        if (!p)
        {
            return 0;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        return sizeOfNoSync(p);
    }


    //
    //
    //
    private size_t sizeOfNoSync(void *p)
    {
        assert (p);

        version (SENTINEL)
        {
            p = sentinel_sub(p);
            size_t size = gcx.findSize(p);

            // Check for interior pointer
            // This depends on:
            // 1) size is a power of 2 for less than PAGESIZE values
            // 2) base of memory pool is aligned on PAGESIZE boundary
            if (cast(size_t)p & (size - 1) & (PAGESIZE - 1))
                size = 0;
            return size ? size - SENTINEL_EXTRA : 0;
        }
        else
        {
            size_t size = gcx.findSize(p);

            // Check for interior pointer
            // This depends on:
            // 1) size is a power of 2 for less than PAGESIZE values
            // 2) base of memory pool is aligned on PAGESIZE boundary
            if (cast(size_t)p & (size - 1) & (PAGESIZE - 1))
                return 0;
            return size;
        }
    }


    /**
     * Determine the base address of the block containing p.  If p is not a gc
     * allocated pointer, return null.
     */
    BlkInfo query(void *p)
    {
        if (!p)
        {
            BlkInfo i;
            return  i;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        return queryNoSync(p);
    }


    //
    //
    //
    BlkInfo queryNoSync(void *p)
    {
        assert(p);

        return gcx.getInfo(p);
    }


    /**
     * Verify that pointer p:
     *  1) belongs to this memory pool
     *  2) points to the start of an allocated piece of memory
     *  3) is not on a free list
     */
    void check(void *p)
    {
        if (!p)
        {
            return;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        checkNoSync(p);
    }


    //
    //
    //
    private void checkNoSync(void *p)
    {
        assert(p);

        sentinel_Invariant(p);
        debug (PTRCHECK)
        {
            Pool*  pool;
            size_t pagenum;
            Bins   bin;
            size_t size;

            p = sentinel_sub(p);
            pool = gcx.findPool(p);
            assert(pool);
            pagenum = cast(size_t)(p - pool.baseAddr) / PAGESIZE;
            bin = cast(Bins)pool.pagetable[pagenum];
            assert(bin <= B_PAGE);
            size = binsize[bin];
            assert((cast(size_t)p & (size - 1)) == 0);

            debug (PTRCHECK2)
            {
                if (bin < B_PAGE)
                {
                    // Check that p is not on a free list
                    List *list;

                    for (list = gcx.bucket[bin]; list; list = list.next)
                    {
                        assert(cast(void*)list != p);
                    }
                }
            }
        }
    }


    /**
     * add p to list of roots
     */
    void addRoot(void *p)
    {
        if (!p)
        {
            return;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        gcx.addRoot(p);
    }


    /**
     * remove p from list of roots
     */
    void removeRoot(void *p)
    {
        if (!p)
        {
            return;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        gcx.removeRoot(p);
    }


    /**
     *
     */
    @property int delegate(int delegate(ref void*)) rootIter()
    {
        gcLock.lock();
        scope(exit) gcLock.unlock();
        return &gcx.rootIter;
    }


    /**
     * add range to scan for roots
     */
    void addRange(void *p, size_t sz)
    {
        if (!p || !sz)
        {
            return;
        }

        //debug(PRINTF) printf("+GC.addRange(p = %p, sz = 0x%zx), p + sz = %p\n", p, sz, p + sz);

        gcLock.lock();
        scope(exit) gcLock.unlock();
        gcx.addRange(p, p + sz);

        //debug(PRINTF) printf("-GC.addRange()\n");
    }


    /**
     * remove range
     */
    void removeRange(void *p)
    {
        if (!p)
        {
            return;
        }

        gcLock.lock();
        scope(exit) gcLock.unlock();
        gcx.removeRange(p);
    }


    /**
     *
     */
    @property int delegate(int delegate(ref Range)) rangeIter()
    {
        gcLock.lock();
        scope(exit) gcLock.unlock();
        return &gcx.rangeIter;
    }


    /**
     * Do full garbage collection.
     * Return number of pages free'd.
     */
    size_t fullCollect()
    {
        debug(PRINTF) printf("GC.fullCollect()\n");
        size_t result;

        // Since a finalizer could launch a new thread, we always need to lock
        // when collecting.
        {
            gcLock.lock();
            scope(exit) gcLock.unlock();
            result = gcx.fullcollect();
        }

        version (none)
        {
            GCStats stats;

            getStats(stats);
            debug(PRINTF) printf("poolsize = %zx, usedsize = %zx, freelistsize = %zx\n",
                    stats.poolsize, stats.usedsize, stats.freelistsize);
        }

        gcx.log_collect();
        return result;
    }


    /**
     * do full garbage collection ignoring roots
     */
    void fullCollectNoStack()
    {
        // Since a finalizer could launch a new thread, we always need to lock
        // when collecting.
        {
            gcLock.lock();
            scope(exit) gcLock.unlock();
            gcx.noStack++;
            gcx.fullcollect();
            gcx.noStack--;
        }
    }


    /**
     * minimize free space usage
     */
    void minimize()
    {
        gcLock.lock();
        scope(exit) gcLock.unlock();
        gcx.minimize();
    }


    /**
     * Retrieve statistics about garbage collection.
     * Useful for debugging and tuning.
     */
    void getStats(out GCStats stats)
    {
        gcLock.lock();
        scope(exit) gcLock.unlock();
        getStatsNoSync(stats);
    }


    //
    //
    //
    private void getStatsNoSync(out GCStats stats)
    {
        size_t psize = 0;
        size_t usize = 0;
        size_t flsize = 0;

        size_t n;
        size_t bsize = 0;

        //debug(PRINTF) printf("getStats()\n");
        memset(&stats, 0, GCStats.sizeof);

        for (n = 0; n < gcx.npools; n++)
        {   Pool *pool = gcx.pooltable[n];

            psize += pool.npages * PAGESIZE;
            for (size_t j = 0; j < pool.npages; j++)
            {
                Bins bin = cast(Bins)pool.pagetable[j];
                if (bin == B_FREE)
                    stats.freeblocks++;
                else if (bin == B_PAGE)
                    stats.pageblocks++;
                else if (bin < B_PAGE)
                    bsize += PAGESIZE;
            }
        }

        for (n = 0; n < B_PAGE; n++)
        {
            //debug(PRINTF) printf("bin %d\n", n);
            for (List *list = gcx.bucket[n]; list; list = list.next)
            {
                //debug(PRINTF) printf("\tlist %p\n", list);
                flsize += binsize[n];
            }
        }

        usize = bsize - flsize;

        stats.poolsize = psize;
        stats.usedsize = bsize - flsize;
        stats.freelistsize = flsize;
    }
}


/* ============================ Gcx =============================== */

enum
{   PAGESIZE =    4096,
    POOLSIZE =   (4096*256),
}


enum
{
    B_16,
    B_32,
    B_64,
    B_128,
    B_256,
    B_512,
    B_1024,
    B_2048,
    B_PAGE,             // start of large alloc
    B_PAGEPLUS,         // continuation of large alloc
    B_FREE,             // free page
    B_MAX
}


alias ubyte Bins;


struct List
{
    List *next;
    Pool *pool;
}


struct Range
{
    void *pbot;
    void *ptop;
}


immutable uint binsize[B_MAX] = [ 16,32,64,128,256,512,1024,2048,4096 ];
immutable size_t notbinsize[B_MAX] = [ ~(16-1),~(32-1),~(64-1),~(128-1),~(256-1),
                                ~(512-1),~(1024-1),~(2048-1),~(4096-1) ];

/* ============================ Gcx =============================== */

struct Gcx
{
    void *cached_size_key;
    size_t cached_size_val;

    void *cached_info_key;
    BlkInfo cached_info_val;

    size_t nroots;
    size_t rootdim;
    void **roots;

    size_t nranges;
    size_t rangedim;
    Range *ranges;

    uint noStack;       // !=0 means don't scan stack
    uint log;           // turn on logging
    uint anychanges;
    uint inited;
    uint running;
    int disabled;       // turn off collections if >0

    byte *minAddr;      // min(baseAddr)
    byte *maxAddr;      // max(topAddr)

    size_t npools;
    Pool **pooltable;

    List *bucket[B_MAX];        // free list for each size


    void initialize()
    {   int dummy;

        (cast(byte*)&this)[0 .. Gcx.sizeof] = 0;
        log_init();
        //printf("gcx = %p, self = %x\n", &this, self);
        inited = 1;
    }


    void Dtor()
    {
        debug(PROFILING)
        {
            printf("\tTotal GC prep time:  %d milliseconds\n",
                prepTime * 1000 / CLOCKS_PER_SEC);
            printf("\tTotal mark time:  %d milliseconds\n",
                markTime * 1000 / CLOCKS_PER_SEC);
            printf("\tTotal sweep time:  %d milliseconds\n",
                sweepTime * 1000 / CLOCKS_PER_SEC);
            printf("\tTotal page recovery time:  %d milliseconds\n",
                recoverTime * 1000 / CLOCKS_PER_SEC);
            printf("\tGrand total GC time:  %d milliseconds\n",
                1000 * (recoverTime + sweepTime + markTime + prepTime)
                / CLOCKS_PER_SEC);
        }

        inited = 0;

        for (size_t i = 0; i < npools; i++)
        {   Pool *pool = pooltable[i];

            pool.Dtor();
            cstdlib.free(pool);
        }
        if (pooltable)
        {
            cstdlib.free(pooltable);
            pooltable = null;
        }

        if (roots)
            cstdlib.free(roots);

        if (ranges)
            cstdlib.free(ranges);
    }


    void Invariant() const { }


    invariant()
    {
        if (inited)
        {
            //printf("Gcx.invariant(): this = %p\n", &this);

            for (size_t i = 0; i < npools; i++)
            {   auto pool = pooltable[i];

                pool.Invariant();
                if (i == 0)
                {
                    assert(minAddr == pool.baseAddr);
                }
                if (i + 1 < npools)
                {
                    assert(pool.opCmp(pooltable[i + 1]) < 0);
                }
                else if (i + 1 == npools)
                {
                    assert(maxAddr == pool.topAddr);
                }
            }

            if (roots)
            {
                assert(rootdim != 0);
                assert(nroots <= rootdim);
            }

            if (ranges)
            {
                assert(rangedim != 0);
                assert(nranges <= rangedim);

                for (size_t i = 0; i < nranges; i++)
                {
                    assert(ranges[i].pbot);
                    assert(ranges[i].ptop);
                    assert(ranges[i].pbot <= ranges[i].ptop);
                }
            }

            for (size_t i = 0; i < B_PAGE; i++)
            {
                for (auto list = cast(List*)bucket[i]; list; list = list.next)
                {
                }
            }
        }
    }


    /**
     *
     */
    void addRoot(void *p)
    {
        if (nroots == rootdim)
        {
            size_t newdim = rootdim * 2 + 16;
            void** newroots;

            newroots = cast(void**)cstdlib.malloc(newdim * newroots[0].sizeof);
            if (!newroots)
                onOutOfMemoryError();
            if (roots)
            {   memcpy(newroots, roots, nroots * newroots[0].sizeof);
                cstdlib.free(roots);
            }
            roots = newroots;
            rootdim = newdim;
        }
        roots[nroots] = p;
        nroots++;
    }


    /**
     *
     */
    void removeRoot(void *p)
    {
        for (size_t i = nroots; i--;)
        {
            if (roots[i] == p)
            {
                nroots--;
                memmove(roots + i, roots + i + 1, (nroots - i) * roots[0].sizeof);
                return;
            }
        }
        assert(0);
    }


    /**
     *
     */
    int rootIter(int delegate(ref void*) dg)
    {
        int result = 0;
        for (size_t i = 0; i < nroots; ++i)
        {
            result = dg(roots[i]);
            if (result)
                break;
        }
        return result;
    }


    /**
     *
     */
    void addRange(void *pbot, void *ptop)
    {
        //debug(PRINTF) printf("Thread %x ", pthread_self());
        debug(PRINTF) printf("%p.Gcx::addRange(%p, %p), nranges = %d\n", &this, pbot, ptop, nranges);
        if (nranges == rangedim)
        {
            size_t newdim = rangedim * 2 + 16;
            Range *newranges;

            newranges = cast(Range*)cstdlib.malloc(newdim * newranges[0].sizeof);
            if (!newranges)
                onOutOfMemoryError();
            if (ranges)
            {   memcpy(newranges, ranges, nranges * newranges[0].sizeof);
                cstdlib.free(ranges);
            }
            ranges = newranges;
            rangedim = newdim;
        }
        ranges[nranges].pbot = pbot;
        ranges[nranges].ptop = ptop;
        nranges++;
    }


    /**
     *
     */
    void removeRange(void *pbot)
    {
        //debug(PRINTF) printf("Thread %x ", pthread_self());
        debug(PRINTF) printf("Gcx.removeRange(%p), nranges = %d\n", pbot, nranges);
        for (size_t i = nranges; i--;)
        {
            if (ranges[i].pbot == pbot)
            {
                nranges--;
                memmove(ranges + i, ranges + i + 1, (nranges - i) * ranges[0].sizeof);
                return;
            }
        }
        debug(PRINTF) printf("Wrong thread\n");

        // This is a fatal error, but ignore it.
        // The problem is that we can get a Close() call on a thread
        // other than the one the range was allocated on.
        //assert(zero);
    }


    /**
     *
     */
    int rangeIter(int delegate(ref Range) dg)
    {
        int result = 0;
        for (size_t i = 0; i < nranges; ++i)
        {
            result = dg(ranges[i]);
            if (result)
                break;
        }
        return result;
    }


    /**
     * Find Pool that pointer is in.
     * Return null if not in a Pool.
     * Assume pooltable[] is sorted.
     */
    Pool *findPool(void *p)
    {
        if (p >= minAddr && p < maxAddr)
        {
            if (npools <= 1)
            {
                return npools == 0 ? null : pooltable[0];
            }

            /* The pooltable[] is sorted by address, so do a binary search
             */
            auto pt = pooltable;
            size_t low = 0;
            size_t high = npools - 1;
            while (low <= high)
            {
                size_t mid = (low + high) >> 1;
                auto pool = pt[mid];
                if (p < pool.baseAddr)
                    high = mid - 1;
                else if (p >= pool.topAddr)
                    low = mid + 1;
                else
                    return pool;
            }
        }
        return null;
    }


    /**
     * Find base address of block containing pointer p.
     * Returns null if not a gc'd pointer
     */
    void* findBase(void *p)
    {
        Pool *pool;

        pool = findPool(p);
        if (pool)
        {
            size_t offset = cast(size_t)(p - pool.baseAddr);
            size_t pn = offset / PAGESIZE;
            Bins   bin = cast(Bins)pool.pagetable[pn];

            // Adjust bit to be at start of allocated memory block
            if (bin <= B_PAGE)
            {
                return pool.baseAddr + (offset & notbinsize[bin]);
            }
            else if (bin == B_PAGEPLUS)
            {
                auto pageOffset = pool.bPageOffsets[pn];
                offset -= pageOffset * PAGESIZE;
                pn -= pageOffset;

                return pool.baseAddr + (offset & (offset.max ^ (PAGESIZE-1)));
            }
            else
            {
                // we are in a B_FREE page
                assert(bin == B_FREE);
                return null;
            }
        }
        return null;
    }


    /**
     * Find size of pointer p.
     * Returns 0 if not a gc'd pointer
     */
    size_t findSize(void *p)
    {
        Pool*  pool;
        size_t size = 0;

        if (USE_CACHE && p == cached_size_key)
            return cached_size_val;

        pool = findPool(p);
        if (pool)
        {
            size_t pagenum;
            Bins   bin;

            pagenum = cast(size_t)(p - pool.baseAddr) / PAGESIZE;
            bin = cast(Bins)pool.pagetable[pagenum];
            size = binsize[bin];
            if (bin == B_PAGE)
            {
                size = pool.bPageOffsets[pagenum] * PAGESIZE;
            }
            cached_size_key = p;
            cached_size_val = size;
        }
        return size;
    }


    /**
     *
     */
    BlkInfo getInfo(void* p)
    {
        Pool*   pool;
        BlkInfo info;

        if (USE_CACHE && p == cached_info_key)
            return cached_info_val;

        pool = findPool(p);
        if (pool)
        {
            size_t offset = cast(size_t)(p - pool.baseAddr);
            size_t pn = offset / PAGESIZE;
            Bins   bin = cast(Bins)pool.pagetable[pn];

            ////////////////////////////////////////////////////////////////////
            // findAddr
            ////////////////////////////////////////////////////////////////////

            if (bin <= B_PAGE)
            {
                info.base = cast(void*)((cast(size_t)p) & notbinsize[bin]);
            }
            else if (bin == B_PAGEPLUS)
            {
                auto pageOffset = pool.bPageOffsets[pn];
                offset = pageOffset * PAGESIZE;
                pn -= pageOffset;
                info.base = pool.baseAddr + (offset & (offset.max ^ (PAGESIZE-1)));

                // fix bin for use by size calc below
                bin = cast(Bins)pool.pagetable[pn];
            }

            ////////////////////////////////////////////////////////////////////
            // findSize
            ////////////////////////////////////////////////////////////////////

            info.size = binsize[bin];
            if (bin == B_PAGE)
            {
                info.size = pool.bPageOffsets[pn] * PAGESIZE;
            }

            ////////////////////////////////////////////////////////////////////
            // getBits
            ////////////////////////////////////////////////////////////////////

            // reset the offset to the base pointer, otherwise the bits
            // are the bits for the pointer, which may be garbage
            offset = cast(size_t)(info.base - pool.baseAddr);
            info.attr = getBits(pool, cast(size_t)(offset >> pool.shiftBy));

            cached_info_key = p;
            cached_info_val = info;
        }
        return info;
    }

    void updateCaches(void*p, size_t size)
    {
        if (USE_CACHE && p == cached_size_key)
            cached_size_val = size;
        if (p == cached_info_key)
            cached_info_val.size = size;
    }

    /**
     * Compute bin for size.
     */
    static Bins findBin(size_t size)
    {
        static const byte[2049] binTable = ctfeBins();

        return (size <= 2048) ?
            (cast(Bins) binTable[size]) :
            B_PAGE;
    }

    static Bins findBinImpl(size_t size)
    {   Bins bin;

        if (size <= 256)
        {
            if (size <= 64)
            {
                if (size <= 16)
                    bin = B_16;
                else if (size <= 32)
                    bin = B_32;
                else
                    bin = B_64;
            }
            else
            {
                if (size <= 128)
                    bin = B_128;
                else
                    bin = B_256;
            }
        }
        else
        {
            if (size <= 1024)
            {
                if (size <= 512)
                    bin = B_512;
                else
                    bin = B_1024;
            }
            else
            {
                if (size <= 2048)
                    bin = B_2048;
                else
                    bin = B_PAGE;
            }
        }
        return bin;
    }

    /**
     * Computes the bin table using CTFE.
     */
    static byte[2049] ctfeBins()
    {
        byte[2049] ret;
        for(size_t i = 0; i < 2049; i++)
        {
            ret[i] = cast(byte) findBinImpl(i);
        }

        return ret;
    }


    /**
     * Allocate a new pool of at least size bytes.
     * Sort it into pooltable[].
     * Mark all memory in the pool as B_FREE.
     * Return the actual number of bytes reserved or 0 on error.
     */
    size_t reserve(size_t size)
    {
        size_t npages = (size + PAGESIZE - 1) / PAGESIZE;

        // Assume reserve() is for small objects.
        Pool*  pool = newPool(npages, false);

        if (!pool)
            return 0;
        return pool.npages * PAGESIZE;
    }


    /**
     * Minimizes physical memory usage by returning free pools to the OS.
     */
    void minimize()
    {
        debug(PRINTF) printf("Minimizing.\n");

        static bool isUsed(Pool *pool)
        {
            return pool.freepages < pool.npages;
        }

        // semi-stable partition
        for (size_t i = 0; i < npools; ++i)
        {
            auto pool = pooltable[i];
            // find first unused pool
            if (isUsed(pool)) continue;

            // move used pools before unused ones
            size_t j = i + 1;
            for (; j < npools; ++j)
            {
                pool = pooltable[j];
                if (!isUsed(pool)) continue;
                // swap
                pooltable[j] = pooltable[i];
                pooltable[i] = pool;
                ++i;
            }
            // npooltable[0 .. i]      => used
            // npooltable[i .. npools] => free

            // free unused pools
            for (j = i; j < npools; ++j)
            {
                pool = pooltable[j];
                debug(PRINTF) printFreeInfo(pool);
                pool.Dtor();
                cstdlib.free(pool);
            }
            npools = i;
        }

        if (npools)
        {
            minAddr = pooltable[0].baseAddr;
            maxAddr = pooltable[npools - 1].topAddr;
        }
        else
        {
            minAddr = maxAddr = null;
        }

        debug(PRINTF) printf("Done minimizing.\n");
    }

    unittest
    {
        enum NPOOLS = 6;
        enum NPAGES = 10;
        Gcx gcx;

        void reset()
        {
            foreach(i, ref pool; gcx.pooltable[0 .. gcx.npools])
                pool.freepages = pool.npages;
            gcx.minimize();
            assert(gcx.npools == 0);

            if (gcx.pooltable is null)
                gcx.pooltable = cast(Pool**)cstdlib.malloc(NPOOLS * (Pool*).sizeof);
            foreach(i; 0 .. NPOOLS)
            {
                auto pool = cast(Pool*)cstdlib.malloc(Pool.sizeof);
                *pool = Pool.init;
                gcx.pooltable[i] = pool;
            }
            gcx.npools = NPOOLS;
        }

        void usePools()
        {
            foreach(pool; gcx.pooltable[0 .. NPOOLS])
            {
                pool.pagetable = cast(ubyte*)cstdlib.malloc(NPAGES);
                memset(pool.pagetable, B_FREE, NPAGES);
                pool.npages = NPAGES;
                pool.freepages = NPAGES / 2;
            }
        }

        // all pools are free
        reset();
        assert(gcx.npools == NPOOLS);
        gcx.minimize();
        assert(gcx.npools == 0);

        // all pools used
        reset();
        usePools();
        assert(gcx.npools == NPOOLS);
        gcx.minimize();
        assert(gcx.npools == NPOOLS);

        // preserves order of used pools
        reset();
        usePools();

        {
            version (Bug7068_FIXED)
                Pool*[NPOOLS] opools = gcx.pooltable[0 .. NPOOLS];
            else
            {
                Pool*[NPOOLS] opools = void;
                memcpy(opools.ptr, gcx.pooltable, (Pool*).sizeof * NPOOLS);
            }
            gcx.pooltable[2].freepages = NPAGES;

            gcx.minimize();
            assert(gcx.npools == NPOOLS - 1);
            assert(gcx.pooltable[0] == opools[0]);
            assert(gcx.pooltable[1] == opools[1]);
            assert(gcx.pooltable[2] == opools[3]);
        }

        // gcx reduces address span
        reset();
        usePools();

        byte* base, top;

        {
            byte*[NPOOLS] mem = void;
            foreach(i; 0 .. NPOOLS)
                mem[i] = cast(byte*)os_mem_map(NPAGES * PAGESIZE);

            extern(C) static int compare(in void* p1, in void *p2)
            {
                return p1 < p2 ? -1 : cast(int)(p2 > p1);
            }
            cstdlib.qsort(mem.ptr, mem.length, (byte*).sizeof, &compare);

            foreach(i, pool; gcx.pooltable[0 .. NPOOLS])
            {
                pool.baseAddr = mem[i];
                pool.topAddr = pool.baseAddr + NPAGES * PAGESIZE;
            }

            base = gcx.pooltable[0].baseAddr;
            top = gcx.pooltable[NPOOLS - 1].topAddr;
        }

        gcx.minimize();
        assert(gcx.npools == NPOOLS);
        assert(gcx.minAddr == base);
        assert(gcx.maxAddr == top);

        gcx.pooltable[NPOOLS - 1].freepages = NPAGES;
        gcx.pooltable[NPOOLS - 2].freepages = NPAGES;

        gcx.minimize();
        assert(gcx.npools == NPOOLS - 2);
        assert(gcx.minAddr == base);
        assert(gcx.maxAddr == gcx.pooltable[NPOOLS - 3].topAddr);

        gcx.pooltable[0].freepages = NPAGES;

        gcx.minimize();
        assert(gcx.npools == NPOOLS - 3);
        assert(gcx.minAddr != base);
        assert(gcx.minAddr == gcx.pooltable[0].baseAddr);
        assert(gcx.maxAddr == gcx.pooltable[NPOOLS - 4].topAddr);

        // free all
        foreach(pool; gcx.pooltable[0 .. gcx.npools])
            pool.freepages = NPAGES;
        gcx.minimize();
        assert(gcx.npools == 0);
        cstdlib.free(gcx.pooltable);
        gcx.pooltable = null;
    }


    /**
     * Allocate a chunk of memory that is larger than a page.
     * Return null if out of memory.
     */
    void *bigAlloc(size_t size, Pool **poolPtr, size_t *alloc_size = null)
    {
        debug(PRINTF) printf("In bigAlloc.  Size:  %d\n", size);

        Pool*  pool;
        size_t npages;
        size_t n;
        size_t pn;
        size_t freedpages;
        void*  p;
        int    state;
        bool   collected = false;

        npages = (size + PAGESIZE - 1) / PAGESIZE;

        for (state = disabled ? 1 : 0; ; )
        {
            // This code could use some refinement when repeatedly
            // allocating very large arrays.

            for (n = 0; n < npools; n++)
            {
                pool = pooltable[n];
                if(!pool.isLargeObject || pool.freepages < npages) continue;
                pn = pool.allocPages(npages);
                if (pn != OPFAIL)
                    goto L1;
            }

            // Failed
            switch (state)
            {
            case 0:
                // Try collecting
                collected = true;
                freedpages = fullcollect();
                if (freedpages >= npools * ((POOLSIZE / PAGESIZE) / 4))
                {   state = 1;
                    continue;
                }
                // Release empty pools to prevent bloat
                minimize();
                // Allocate new pool
                pool = newPool(npages, true);
                if (!pool)
                {   state = 2;
                    continue;
                }
                pn = pool.allocPages(npages);
                assert(pn != OPFAIL);
                goto L1;
            case 1:
                // Release empty pools to prevent bloat
                minimize();
                // Allocate new pool
                pool = newPool(npages, true);
                if (!pool)
                {
                    if (collected)
                        goto Lnomemory;
                    state = 0;
                    continue;
                }
                pn = pool.allocPages(npages);
                assert(pn != OPFAIL);
                goto L1;
            case 2:
                goto Lnomemory;
            default:
                assert(false);
            }
        }

      L1:
        debug(PRINTF) printFreeInfo(pool);
        pool.pagetable[pn] = B_PAGE;
        if (npages > 1)
            memset(&pool.pagetable[pn + 1], B_PAGEPLUS, npages - 1);
        pool.updateOffsets(pn);
        pool.freepages -= npages;

        debug(PRINTF) printFreeInfo(pool);

        p = pool.baseAddr + pn * PAGESIZE;
        debug(PRINTF) printf("Got large alloc:  %p, pt = %d, np = %d\n", p, pool.pagetable[pn], npages);
        debug (MEMSTOMP) memset(p, 0xF1, size);
        if(alloc_size)
            *alloc_size = npages * PAGESIZE;
        //debug(PRINTF) printf("\tp = %p\n", p);

        *poolPtr = pool;
        return p;

      Lnomemory:
        return null; // let caller handle the error
    }


    /**
     * Allocate a new pool with at least npages in it.
     * Sort it into pooltable[].
     * Return null if failed.
     */
    Pool *newPool(size_t npages, bool isLargeObject)
    {
        Pool*  pool;
        Pool** newpooltable;
        size_t newnpools;
        size_t i;

        //debug(PRINTF) printf("************Gcx::newPool(npages = %d)****************\n", npages);

        // Minimum of POOLSIZE
        if (npages < POOLSIZE/PAGESIZE)
            npages = POOLSIZE/PAGESIZE;
        else if (npages > POOLSIZE/PAGESIZE)
        {   // Give us 150% of requested size, so there's room to extend
            auto n = npages + (npages >> 1);
            if (n < size_t.max/PAGESIZE)
                npages = n;
        }

        // Allocate successively larger pools up to 8 megs
        if (npools)
        {   size_t n;

            n = npools;
            if (n > 32)
                n = 32;                 // cap pool size at 32 megs
            else if (n > 8)
                n = 16;
            n *= (POOLSIZE / PAGESIZE);
            if (npages < n)
                npages = n;
        }

        //printf("npages = %d\n", npages);

        pool = cast(Pool *)cstdlib.calloc(1, Pool.sizeof);
        if (pool)
        {
            pool.initialize(npages, isLargeObject);
            if (!pool.baseAddr)
                goto Lerr;

            newnpools = npools + 1;
            newpooltable = cast(Pool **)cstdlib.realloc(pooltable, newnpools * (Pool *).sizeof);
            if (!newpooltable)
                goto Lerr;

            // Sort pool into newpooltable[]
            for (i = 0; i < npools; i++)
            {
                if (pool.opCmp(newpooltable[i]) < 0)
                     break;
            }
            memmove(newpooltable + i + 1, newpooltable + i, (npools - i) * (Pool *).sizeof);
            newpooltable[i] = pool;

            pooltable = newpooltable;
            npools = newnpools;

            minAddr = pooltable[0].baseAddr;
            maxAddr = pooltable[npools - 1].topAddr;
        }
        return pool;

      Lerr:
        pool.Dtor();
        cstdlib.free(pool);
        return null;
    }


    /**
     * Allocate a page of bin's.
     * Returns:
     *  0       failed
     */
    int allocPage(Bins bin)
    {
        Pool*  pool;
        size_t n;
        size_t pn;
        byte*  p;
        byte*  ptop;

        //debug(PRINTF) printf("Gcx::allocPage(bin = %d)\n", bin);
        for (n = 0; n < npools; n++)
        {
            pool = pooltable[n];
            if(pool.isLargeObject) continue;
            pn = pool.allocPages(1);
            if (pn != OPFAIL)
                goto L1;
        }
        return 0;               // failed

      L1:
        pool.pagetable[pn] = cast(ubyte)bin;
        pool.freepages--;

        // Convert page to free list
        size_t size = binsize[bin];
        List **b = &bucket[bin];

        p = pool.baseAddr + pn * PAGESIZE;
        ptop = p + PAGESIZE;
        for (; p < ptop; p += size)
        {
            (cast(List *)p).next = *b;
            (cast(List *)p).pool = pool;
            *b = cast(List *)p;
        }
        return 1;
    }

    /**
     * Mark overload for initial mark() call.
     */
    void mark(void *pbot, void *ptop) {
        mark(pbot, ptop, MAX_MARK_RECURSIONS);
    }

    /**
     * Search a range of memory values and mark any pointers into the GC pool.
     */
    void mark(void *pbot, void *ptop, int nRecurse)
    {
        //import core.stdc.stdio;printf("nRecurse = %d\n", nRecurse);
        void **p1 = cast(void **)pbot;
        void **p2 = cast(void **)ptop;
        size_t pcache = 0;
        uint changes = 0;

        //printf("marking range: %p -> %p\n", pbot, ptop);
        for (; p1 < p2; p1++)
        {
            auto p = cast(byte *)(*p1);

            //if (log) debug(PRINTF) printf("\tmark %p\n", p);
            if (p >= minAddr && p < maxAddr)
            {
                if ((cast(size_t)p & ~cast(size_t)(PAGESIZE-1)) == pcache)
                    continue;

                auto pool = findPool(p);
                if (pool)
                {
                    size_t offset = cast(size_t)(p - pool.baseAddr);
                    size_t biti = void;
                    size_t pn = offset / PAGESIZE;
                    Bins   bin = cast(Bins)pool.pagetable[pn];
                    void* base = void;

                    // For the NO_INTERIOR attribute.  This tracks whether
                    // the pointer is an interior pointer or points to the
                    // base address of a block.
                    bool pointsToBase = false;

                    //debug(PRINTF) printf("\t\tfound pool %p, base=%p, pn = %zd, bin = %d, biti = x%x\n", pool, pool.baseAddr, pn, bin, biti);

                    // Adjust bit to be at start of allocated memory block
                    if (bin < B_PAGE)
                    {
                        // We don't care abou setting pointsToBase correctly
                        // because it's ignored for small object pools anyhow.
                        auto offsetBase = offset & notbinsize[bin];
                        biti = offsetBase >> pool.shiftBy;
                        base = pool.baseAddr + offsetBase;
                        //debug(PRINTF) printf("\t\tbiti = x%x\n", biti);
                    }
                    else if (bin == B_PAGE)
                    {
                        auto offsetBase = offset & notbinsize[bin];
                        base = pool.baseAddr + offsetBase;
                        pointsToBase = offsetBase == offset;
                        biti = offsetBase >> pool.shiftBy;
                        //debug(PRINTF) printf("\t\tbiti = x%x\n", biti);

                        pcache = cast(size_t)p & ~cast(size_t)(PAGESIZE-1);
                    }
                    else if (bin == B_PAGEPLUS)
                    {
                        pn -= pool.bPageOffsets[pn];
                        base = pool.baseAddr + (pn * PAGESIZE);
                        biti = pn * (PAGESIZE >> pool.shiftBy);
                        pcache = cast(size_t)p & ~cast(size_t)(PAGESIZE-1);
                    }
                    else
                    {
                        // Don't mark bits in B_FREE pages
                        assert(bin == B_FREE);
                        continue;
                    }

                    if(pool.nointerior.nbits && !pointsToBase && pool.nointerior.test(biti))
                    {
                        continue;
                    }

                    //debug(PRINTF) printf("\t\tmark(x%x) = %d\n", biti, pool.mark.test(biti));
                    if (!pool.mark.testSet(biti))
                    {
                        //if (log) debug(PRINTF) printf("\t\tmarking %p\n", p);
                        if (!pool.noscan.test(biti))
                        {
                            if(nRecurse == 0) {
                                // Then we've got a really deep heap graph.
                                // Start marking stuff to be scanned when we
                                // traverse the heap again next time, to save
                                // stack space.
                                pool.scan.set(biti);
                                changes = 1;
                                pool.newChanges = true;
                            } else {
                                // Directly recurse mark() to prevent having
                                // to traverse the heap O(D) times where D
                                // is the max depth of the heap graph.
                                if (bin < B_PAGE)
                                {
                                    mark(base, base + binsize[bin], nRecurse - 1);
                                }
                                else
                                {
                                    auto u = pool.bPageOffsets[pn];
                                    mark(base, base + u * PAGESIZE, nRecurse - 1);
                                }
                            }
                        }

                        debug (LOGGING) log_parent(sentinel_add(pool.baseAddr + (biti << pool.shiftBy)), sentinel_add(pbot));
                    }
                }
            }
        }
        anychanges |= changes;
    }


    /**
     * Return number of full pages free'd.
     */
    size_t fullcollect()
    {
        size_t n;
        Pool*  pool;

        debug(PROFILING)
        {
            clock_t start, stop;
            start = clock();
        }

        debug(COLLECT_PRINTF) printf("Gcx.fullcollect()\n");
        //printf("\tpool address range = %p .. %p\n", minAddr, maxAddr);

        if (running)
            onInvalidMemoryOperationError();
        running = 1;

        thread_suspendAll();

        cached_size_key = cached_size_key.init;
        cached_size_val = cached_size_val.init;
        cached_info_key = cached_info_key.init;
        cached_info_val = cached_info_val.init;

        anychanges = 0;
        for (n = 0; n < npools; n++)
        {
            pool = pooltable[n];
            pool.mark.zero();
            pool.scan.zero();
            if(!pool.isLargeObject) pool.freebits.zero();
        }

        debug(COLLECT_PRINTF) printf("Set bits\n");

        // Mark each free entry, so it doesn't get scanned
        for (n = 0; n < B_PAGE; n++)
        {
            for (List *list = bucket[n]; list; list = list.next)
            {
                pool = list.pool;
                assert(pool);
                pool.freebits.set(cast(size_t)(cast(byte*)list - pool.baseAddr) / 16);
            }
        }

        debug(COLLECT_PRINTF) printf("Marked free entries.\n");

        for (n = 0; n < npools; n++)
        {
            pool = pooltable[n];
            pool.newChanges = false;  // Some of these get set to true on stack scan.
            if(!pool.isLargeObject)
            {
                pool.mark.copy(&pool.freebits);
            }
        }

        debug(PROFILING)
        {
            stop = clock();
            prepTime += (stop - start);
            start = stop;
        }

        if (!noStack)
        {
            debug(COLLECT_PRINTF) printf("\tscan stacks.\n");
            // Scan stacks and registers for each paused thread
            thread_scanAll(&mark);
        }

        // Scan roots[]
        debug(COLLECT_PRINTF) printf("\tscan roots[]\n");
        mark(roots, roots + nroots);

        // Scan ranges[]
        debug(COLLECT_PRINTF) printf("\tscan ranges[]\n");
        //log++;
        for (n = 0; n < nranges; n++)
        {
            debug(COLLECT_PRINTF) printf("\t\t%p .. %p\n", ranges[n].pbot, ranges[n].ptop);
            mark(ranges[n].pbot, ranges[n].ptop);
        }
        //log--;

        debug(COLLECT_PRINTF) printf("\tscan heap\n");
        int nTraversals;
        while (anychanges)
        {
            //import core.stdc.stdio;  printf("nTraversals = %d\n", ++nTraversals);
            for (n = 0; n < npools; n++)
            {
                pool = pooltable[n];
                pool.oldChanges = pool.newChanges;
                pool.newChanges = false;
            }

            debug(COLLECT_PRINTF) printf("\t\tpass\n");
            anychanges = 0;
            for (n = 0; n < npools; n++)
            {
                pool = pooltable[n];
                if(!pool.oldChanges) continue;

                auto shiftBy = pool.shiftBy;
                auto bbase = pool.scan.base();
                auto btop = bbase + pool.scan.nwords;
                //printf("\t\tn = %d, bbase = %p, btop = %p\n", n, bbase, btop);
                for (auto b = bbase; b < btop;)
                {
                    auto bitm = *b;
                    if (!bitm)
                    {   b++;
                        continue;
                    }
                    *b = 0;

                    auto o = pool.baseAddr + (b - bbase) * ((typeof(bitm).sizeof*8) << shiftBy);

                    auto firstset = bsf(bitm);
                    bitm >>= firstset;
                    o += firstset << shiftBy;

                    while(bitm)
                    {
                        auto pn = cast(size_t)(o - pool.baseAddr) / PAGESIZE;
                        auto bin = cast(Bins)pool.pagetable[pn];
                        if (bin < B_PAGE)
                        {
                            mark(o, o + binsize[bin]);
                        }
                        else if (bin == B_PAGE)
                        {
                            auto u = pool.bPageOffsets[pn];
                            mark(o, o + u * PAGESIZE);
                        }

                        bitm >>= 1;
                        auto nbits = bsf(bitm);
                        bitm >>= nbits;
                        o += (nbits + 1) << shiftBy;
                    }
                }
            }
        }

        thread_processGCMarks(&isMarked);
        thread_resumeAll();

        debug(PROFILING)
        {
            stop = clock();
            markTime += (stop - start);
            start = stop;
        }

        // Free up everything not marked
        debug(COLLECT_PRINTF) printf("\tfree'ing\n");
        size_t freedpages = 0;
        size_t freed = 0;
        for (n = 0; n < npools; n++)
        {   size_t pn;

            pool = pooltable[n];

            if(pool.isLargeObject)
            {
                for(pn = 0; pn < pool.npages; pn++)
                {
                    Bins bin = cast(Bins)pool.pagetable[pn];
                    if(bin > B_PAGE) continue;
                    size_t biti = pn;

                    if (!pool.mark.test(biti))
                    {   byte *p = pool.baseAddr + pn * PAGESIZE;

                        sentinel_Invariant(sentinel_add(p));
                        if (pool.finals.nbits && pool.finals.testClear(biti))
                            rt_finalize2(sentinel_add(p), false, false);
                        clrBits(pool, biti, ~BlkAttr.NONE ^ BlkAttr.FINALIZE);

                        debug(COLLECT_PRINTF) printf("\tcollecting big %p\n", p);
                        log_free(sentinel_add(p));
                        pool.pagetable[pn] = B_FREE;
                        if(pn < pool.searchStart) pool.searchStart = pn;
                        freedpages++;
                        pool.freepages++;

                        debug (MEMSTOMP) memset(p, 0xF3, PAGESIZE);
                        while (pn + 1 < pool.npages && pool.pagetable[pn + 1] == B_PAGEPLUS)
                        {
                            pn++;
                            pool.pagetable[pn] = B_FREE;

                            // Don't need to update searchStart here because
                            // pn is guaranteed to be greater than last time
                            // we updated it.

                            pool.freepages++;
                            freedpages++;

                            debug (MEMSTOMP)
                            {   p += PAGESIZE;
                                memset(p, 0xF3, PAGESIZE);
                            }
                        }
                    }
                }
            }
            else
            {

                for (pn = 0; pn < pool.npages; pn++)
                {
                    Bins bin = cast(Bins)pool.pagetable[pn];

                    if (bin < B_PAGE)
                    {
                        auto   size = binsize[bin];
                        byte *p = pool.baseAddr + pn * PAGESIZE;
                        byte *ptop = p + PAGESIZE;
                        size_t biti = pn * (PAGESIZE/16);
                        size_t bitstride = size / 16;

                        GCBits.wordtype toClear;
                        size_t clearStart = (biti >> GCBits.BITS_SHIFT) + 1;
                        size_t clearIndex;

                        for (; p < ptop; p += size, biti += bitstride, clearIndex += bitstride)
                        {
                            if(clearIndex > GCBits.BITS_PER_WORD - 1)
                            {
                                if(toClear)
                                {
                                    Gcx.clrBitsSmallSweep(pool, clearStart, toClear);
                                    toClear = 0;
                                }

                                clearStart = (biti >> GCBits.BITS_SHIFT) + 1;
                                clearIndex = biti & GCBits.BITS_MASK;
                            }

                            if (!pool.mark.test(biti))
                            {
                                sentinel_Invariant(sentinel_add(p));

                                pool.freebits.set(biti);
                                if (pool.finals.nbits && pool.finals.test(biti))
                                    rt_finalize2(sentinel_add(p), false, false);
                                toClear |= GCBits.BITS_1 << clearIndex;

                                List *list = cast(List *)p;
                                debug(COLLECT_PRINTF) printf("\tcollecting %p\n", list);
                                log_free(sentinel_add(list));

                                debug (MEMSTOMP) memset(p, 0xF3, size);

                                freed += size;
                            }
                        }

                        if(toClear)
                        {
                            Gcx.clrBitsSmallSweep(pool, clearStart, toClear);
                        }
                    }
                }
            }
        }

        debug(PROFILING)
        {
            stop = clock();
            sweepTime += (stop - start);
            start = stop;
        }

        // Zero buckets
        bucket[] = null;

        // Free complete pages, rebuild free list
        debug(COLLECT_PRINTF) printf("\tfree complete pages\n");
        size_t recoveredpages = 0;
        for (n = 0; n < npools; n++)
        {   size_t pn;

            pool = pooltable[n];
            if(pool.isLargeObject) continue;
            for (pn = 0; pn < pool.npages; pn++)
            {
                Bins   bin = cast(Bins)pool.pagetable[pn];
                size_t biti;
                size_t u;

                if (bin < B_PAGE)
                {
                    size_t size = binsize[bin];
                    size_t bitstride = size / 16;
                    size_t bitbase = pn * (PAGESIZE / 16);
                    size_t bittop = bitbase + (PAGESIZE / 16);
                    byte*  p;

                    biti = bitbase;
                    for (biti = bitbase; biti < bittop; biti += bitstride)
                    {   if (!pool.freebits.test(biti))
                            goto Lnotfree;
                    }
                    pool.pagetable[pn] = B_FREE;
                    if(pn < pool.searchStart) pool.searchStart = pn;
                    pool.freepages++;
                    recoveredpages++;
                    continue;

                 Lnotfree:
                    p = pool.baseAddr + pn * PAGESIZE;
                    for (u = 0; u < PAGESIZE; u += size)
                    {   biti = bitbase + u / 16;
                        if (pool.freebits.test(biti))
                        {   List *list;

                            list = cast(List *)(p + u);
                            if (list.next != bucket[bin])       // avoid unnecessary writes
                                list.next = bucket[bin];
                            list.pool = pool;
                            bucket[bin] = list;
                        }
                    }
                }
            }
        }

        debug(PROFILING)
        {
            stop = clock();
            recoverTime += (stop - start);
        }

        debug(COLLECT_PRINTF) printf("\trecovered pages = %d\n", recoveredpages);
        debug(COLLECT_PRINTF) printf("\tfree'd %u bytes, %u pages from %u pools\n", freed, freedpages, npools);

        running = 0; // only clear on success

        return freedpages + recoveredpages;
    }

    /**
     * Returns true if the addr lies within a marked block.
     *
     * Warning! This should only be called while the world is stopped inside
     * the fullcollect function.
     */
    IsMarked isMarked(void *addr)
    {
        // first, we find the Pool this block is in, then check to see if the
        // mark bit is clear.
        auto pool = findPool(addr);
        if(pool)
        {
            auto offset = cast(size_t)(addr - pool.baseAddr);
            auto pn = offset / PAGESIZE;
            auto bins = cast(Bins)pool.pagetable[pn];
            size_t biti = void;
            if(bins <= B_PAGE)
            {
                biti = (offset & notbinsize[bins]) >> pool.shiftBy;
            }
            else if(bins == B_PAGEPLUS)
            {
                pn -= pool.bPageOffsets[pn];
                biti = pn * (PAGESIZE >> pool.shiftBy);
            }
            else // bins == B_FREE
            {
                assert(bins == B_FREE);
                return IsMarked.no;
            }
            return pool.mark.test(biti) ? IsMarked.yes : IsMarked.no;
        }
        return IsMarked.unknown;
    }


    /**
     *
     */
    uint getBits(Pool* pool, size_t biti)
    in
    {
        assert(pool);
    }
    body
    {
        uint bits;

        if (pool.finals.nbits &&
            pool.finals.test(biti))
            bits |= BlkAttr.FINALIZE;
        if (pool.noscan.test(biti))
            bits |= BlkAttr.NO_SCAN;
        if (pool.nointerior.nbits && pool.nointerior.test(biti))
            bits |= BlkAttr.NO_INTERIOR;
//        if (pool.nomove.nbits &&
//            pool.nomove.test(biti))
//            bits |= BlkAttr.NO_MOVE;
        if (pool.appendable.test(biti))
            bits |= BlkAttr.APPENDABLE;
        return bits;
    }


    /**
     *
     */
    void setBits(Pool* pool, size_t biti, uint mask)
    in
    {
        assert(pool);
    }
    body
    {
        // Calculate the mask and bit offset once and then use it to
        // set all of the bits we need to set.
        immutable dataIndex = 1 + (biti >> GCBits.BITS_SHIFT);
        immutable bitOffset = biti & GCBits.BITS_MASK;
        immutable orWith = GCBits.BITS_1 << bitOffset;

        if (mask & BlkAttr.FINALIZE)
        {
            if (!pool.finals.nbits)
                pool.finals.alloc(pool.mark.nbits);
            pool.finals.data[dataIndex] |= orWith;
        }
        if (mask & BlkAttr.NO_SCAN)
        {
            pool.noscan.data[dataIndex] |= orWith;
        }
//        if (mask & BlkAttr.NO_MOVE)
//        {
//            if (!pool.nomove.nbits)
//                pool.nomove.alloc(pool.mark.nbits);
//            pool.nomove.data[dataIndex] |= orWith;
//        }
        if (mask & BlkAttr.APPENDABLE)
        {
            pool.appendable.data[dataIndex] |= orWith;
        }

        if (pool.isLargeObject && (mask & BlkAttr.NO_INTERIOR))
        {
            if(!pool.nointerior.nbits)
                pool.nointerior.alloc(pool.mark.nbits);
            pool.nointerior.data[dataIndex] |= orWith;
        }
    }


    /**
     *
     */
    void clrBits(Pool* pool, size_t biti, uint mask)
    in
    {
        assert(pool);
    }
    body
    {
        immutable dataIndex =  1 + (biti >> GCBits.BITS_SHIFT);
        immutable bitOffset = biti & GCBits.BITS_MASK;
        immutable keep = ~(GCBits.BITS_1 << bitOffset);

        if (mask & BlkAttr.FINALIZE && pool.finals.nbits)
            pool.finals.data[dataIndex] &= keep;
        if (mask & BlkAttr.NO_SCAN)
            pool.noscan.data[dataIndex] &= keep;
//        if (mask & BlkAttr.NO_MOVE && pool.nomove.nbits)
//            pool.nomove.data[dataIndex] &= keep;
        if (mask & BlkAttr.APPENDABLE)
            pool.appendable.data[dataIndex] &= keep;
        if (pool.nointerior.nbits && (mask & BlkAttr.NO_INTERIOR))
            pool.nointerior.data[dataIndex] &= keep;
    }

    void clrBitsSmallSweep(Pool* pool, size_t dataIndex, GCBits.wordtype toClear)
    in
    {
        assert(pool);
    }
    body
    {
        immutable toKeep = ~toClear;
        if (pool.finals.nbits)
            pool.finals.data[dataIndex] &= toKeep;

        pool.noscan.data[dataIndex] &= toKeep;

//        if (pool.nomove.nbits)
//            pool.nomove.data[dataIndex] &= toKeep;

        pool.appendable.data[dataIndex] &= toKeep;

        if (pool.nointerior.nbits)
            pool.nointerior.data[dataIndex] &= toKeep;
    }

    /***** Leak Detector ******/


    debug (LOGGING)
    {
        LogArray current;
        LogArray prev;


        void log_init()
        {
            //debug(PRINTF) printf("+log_init()\n");
            current.reserve(1000);
            prev.reserve(1000);
            //debug(PRINTF) printf("-log_init()\n");
        }


        void log_malloc(void *p, size_t size)
        {
            //debug(PRINTF) printf("+log_malloc(p = %p, size = %zd)\n", p, size);
            Log log;

            log.p = p;
            log.size = size;
            log.line = GC.line;
            log.file = GC.file;
            log.parent = null;

            GC.line = 0;
            GC.file = null;

            current.push(log);
            //debug(PRINTF) printf("-log_malloc()\n");
        }


        void log_free(void *p)
        {
            //debug(PRINTF) printf("+log_free(%p)\n", p);
            auto i = current.find(p);
            if (i == OPFAIL)
            {
                debug(PRINTF) printf("free'ing unallocated memory %p\n", p);
            }
            else
                current.remove(i);
            //debug(PRINTF) printf("-log_free()\n");
        }


        void log_collect()
        {
            //debug(PRINTF) printf("+log_collect()\n");
            // Print everything in current that is not in prev

            debug(PRINTF) printf("New pointers this cycle: --------------------------------\n");
            size_t used = 0;
            for (size_t i = 0; i < current.dim; i++)
            {
                auto j = prev.find(current.data[i].p);
                if (j == OPFAIL)
                    current.data[i].print();
                else
                    used++;
            }

            debug(PRINTF) printf("All roots this cycle: --------------------------------\n");
            for (size_t i = 0; i < current.dim; i++)
            {
                void* p = current.data[i].p;
                if (!findPool(current.data[i].parent))
                {
                    auto j = prev.find(current.data[i].p);
                    debug(PRINTF) printf(j == OPFAIL ? "N" : " ");
                    current.data[i].print();
                }
            }

            debug(PRINTF) printf("Used = %d-------------------------------------------------\n", used);
            prev.copy(&current);

            debug(PRINTF) printf("-log_collect()\n");
        }


        void log_parent(void *p, void *parent)
        {
            //debug(PRINTF) printf("+log_parent()\n");
            auto i = current.find(p);
            if (i == OPFAIL)
            {
                debug(PRINTF) printf("parent'ing unallocated memory %p, parent = %p\n", p, parent);
                Pool *pool;
                pool = findPool(p);
                assert(pool);
                size_t offset = cast(size_t)(p - pool.baseAddr);
                size_t biti;
                size_t pn = offset / PAGESIZE;
                Bins bin = cast(Bins)pool.pagetable[pn];
                biti = (offset & notbinsize[bin]);
                debug(PRINTF) printf("\tbin = %d, offset = x%x, biti = x%x\n", bin, offset, biti);
            }
            else
            {
                current.data[i].parent = parent;
            }
            //debug(PRINTF) printf("-log_parent()\n");
        }

    }
    else
    {
        void log_init() { }
        void log_malloc(void *p, size_t size) { }
        void log_free(void *p) { }
        void log_collect() { }
        void log_parent(void *p, void *parent) { }
    }
}


/* ============================ Pool  =============================== */


struct Pool
{
    byte* baseAddr;
    byte* topAddr;
    GCBits mark;        // entries already scanned, or should not be scanned
    GCBits scan;        // entries that need to be scanned
    GCBits freebits;    // entries that are on the free list
    GCBits finals;      // entries that need finalizer run on them
    GCBits noscan;      // entries that should not be scanned
    GCBits appendable;  // entries that are appendable
    GCBits nointerior;  // interior pointers should be ignored.
                        // Only implemented for large object pools.

    size_t npages;
    size_t freepages;     // The number of pages not in use.
    ubyte* pagetable;

    bool isLargeObject;
    bool oldChanges;  // Whether there were changes on the last mark.
    bool newChanges;  // Whether there were changes on the current mark.

    // This tracks how far back we have to go to find the nearest B_PAGE at
    // a smaller address than a B_PAGEPLUS.  To save space, we use a uint.
    // This limits individual allocations to 16 terabytes, assuming a 4k
    // pagesize.
    uint* bPageOffsets;

    // This variable tracks a conservative estimate of where the first free
    // page in this pool is, so that if a lot of pages towards the beginning
    // are occupied, we can bypass them in O(1).
    size_t searchStart;

    void initialize(size_t npages, bool isLargeObject)
    {
        this.isLargeObject = isLargeObject;
        size_t poolsize;

        //debug(PRINTF) printf("Pool::Pool(%u)\n", npages);
        poolsize = npages * PAGESIZE;
        assert(poolsize >= POOLSIZE);
        baseAddr = cast(byte *)os_mem_map(poolsize);

        // Some of the code depends on page alignment of memory pools
        assert((cast(size_t)baseAddr & (PAGESIZE - 1)) == 0);

        if (!baseAddr)
        {
            //debug(PRINTF) printf("GC fail: poolsize = x%zx, errno = %d\n", poolsize, errno);
            //debug(PRINTF) printf("message = '%s'\n", sys_errlist[errno]);

            npages = 0;
            poolsize = 0;
        }
        //assert(baseAddr);
        topAddr = baseAddr + poolsize;
        auto div = this.divisor;
        auto nbits = cast(size_t)poolsize / div;

        mark.alloc(nbits);
        scan.alloc(nbits);

        // pagetable already keeps track of what's free for the large object
        // pool.
        if(!isLargeObject)
        {
            freebits.alloc(nbits);
        }

        noscan.alloc(nbits);
        appendable.alloc(nbits);

        pagetable = cast(ubyte*)cstdlib.malloc(npages);
        if (!pagetable)
            onOutOfMemoryError();

        if(isLargeObject)
        {
            bPageOffsets = cast(uint*)cstdlib.malloc(npages * uint.sizeof);
            if (!bPageOffsets)
                onOutOfMemoryError();
        }

        memset(pagetable, B_FREE, npages);

        this.npages = npages;
        this.freepages = npages;
    }


    void Dtor()
    {
        if (baseAddr)
        {
            int result;

            if (npages)
            {
                result = os_mem_unmap(baseAddr, npages * PAGESIZE);
                assert(result == 0);
                npages = 0;
            }

            baseAddr = null;
            topAddr = null;
        }
        if (pagetable)
        {
            cstdlib.free(pagetable);
            pagetable = null;
        }

        if(bPageOffsets)
            cstdlib.free(bPageOffsets);

        mark.Dtor();
        scan.Dtor();
        if(isLargeObject)
        {
            nointerior.Dtor();
        }
        else
        {
            freebits.Dtor();
        }
        finals.Dtor();
        noscan.Dtor();
        appendable.Dtor();
    }


    void Invariant() const {}


    invariant()
    {
        //mark.Invariant();
        //scan.Invariant();
        //freebits.Invariant();
        //finals.Invariant();
        //noscan.Invariant();
        //appendable.Invariant();
        //nointerior.Invariant();

        if (baseAddr)
        {
            //if (baseAddr + npages * PAGESIZE != topAddr)
                //printf("baseAddr = %p, npages = %d, topAddr = %p\n", baseAddr, npages, topAddr);
            assert(baseAddr + npages * PAGESIZE == topAddr);
        }

        if(pagetable !is null)
        {
            for (size_t i = 0; i < npages; i++)
            {
                Bins bin = cast(Bins)pagetable[i];
                assert(bin < B_MAX);
            }
        }
    }

    // The divisor used for determining bit indices.
    @property private size_t divisor()
    {
        // NOTE: Since this is called by initialize it must be private or
        //       invariant() will be called and fail.
        return isLargeObject ? PAGESIZE : 16;
    }

    // Bit shift for fast division by divisor.
    @property uint shiftBy()
    {
        return isLargeObject ? 12 : 4;
    }

    void updateOffsets(size_t fromWhere)
    {
        assert(pagetable[fromWhere] == B_PAGE);
        size_t pn = fromWhere + 1;
        for(uint offset = 1; pn < npages; pn++, offset++)
        {
            if(pagetable[pn] != B_PAGEPLUS) break;
            bPageOffsets[pn] = offset;
        }

        // Store the size of the block in bPageOffsets[fromWhere].
        bPageOffsets[fromWhere] = cast(uint) (pn - fromWhere);
    }

    /**
     * Allocate n pages from Pool.
     * Returns OPFAIL on failure.
     */
    size_t allocPages(size_t n)
    {
        if(freepages < n) return OPFAIL;
        size_t i;
        size_t n2;

        //debug(PRINTF) printf("Pool::allocPages(n = %d)\n", n);
        n2 = n;
        for (i = searchStart; i < npages; i++)
        {
            if (pagetable[i] == B_FREE)
            {
                if(pagetable[searchStart] < B_FREE)
                {
                    searchStart = i + (!isLargeObject);
                }

                if (--n2 == 0)
                {   //debug(PRINTF) printf("\texisting pn = %d\n", i - n + 1);
                    return i - n + 1;
                }
            }
            else
            {
                n2 = n;
                if(pagetable[i] == B_PAGE)
                {
                    // Then we have the offset information.  We can skip a
                    // whole bunch of stuff.
                    i += bPageOffsets[i] - 1;
                }
            }
        }

        if(pagetable[searchStart] < B_FREE)
        {
            searchStart = npages;
        }

        return OPFAIL;
    }

    /**
     * Free npages pages starting with pagenum.
     */
    void freePages(size_t pagenum, size_t npages)
    {
        //memset(&pagetable[pagenum], B_FREE, npages);
        if(pagenum < searchStart) searchStart = pagenum;

        for(size_t i = pagenum; i < npages + pagenum; i++)
        {
            if(pagetable[i] < B_FREE)
            {
                freepages++;
            }

            pagetable[i] = B_FREE;
        }
    }


    /**
     * Used for sorting pooltable[]
     */
    int opCmp(const Pool *p2) const
    {
        if (baseAddr < p2.baseAddr)
            return -1;
        else
            return cast(int)(baseAddr > p2.baseAddr);
    }
}


/* ============================ SENTINEL =============================== */


version (SENTINEL)
{
    const size_t SENTINEL_PRE = cast(size_t) 0xF4F4F4F4F4F4F4F4UL; // 32 or 64 bits
    const ubyte SENTINEL_POST = 0xF5;           // 8 bits
    const uint SENTINEL_EXTRA = 2 * size_t.sizeof + 1;


    size_t* sentinel_size(void *p)  { return &(cast(size_t *)p)[-2]; }
    size_t* sentinel_pre(void *p)   { return &(cast(size_t *)p)[-1]; }
    ubyte* sentinel_post(void *p) { return &(cast(ubyte *)p)[*sentinel_size(p)]; }


    void sentinel_init(void *p, size_t size)
    {
        *sentinel_size(p) = size;
        *sentinel_pre(p) = SENTINEL_PRE;
        *sentinel_post(p) = SENTINEL_POST;
    }


    void sentinel_Invariant(const void *p)
    {
        assert(*sentinel_pre(p) == SENTINEL_PRE);
        assert(*sentinel_post(p) == SENTINEL_POST);
    }


    void *sentinel_add(void *p)
    {
        return p + 2 * size_t.sizeof;
    }


    void *sentinel_sub(void *p)
    {
        return p - 2 * size_t.sizeof;
    }
}
else
{
    const uint SENTINEL_EXTRA = 0;


    void sentinel_init(void *p, size_t size)
    {
    }


    void sentinel_Invariant(const void *p)
    {
    }


    void *sentinel_add(void *p)
    {
        return p;
    }


    void *sentinel_sub(void *p)
    {
        return p;
    }
}
