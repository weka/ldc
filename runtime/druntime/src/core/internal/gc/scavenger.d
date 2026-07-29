/**
 * WEKA page-level GC scavenger.
 *
 * Returns whole free (B_FREE) pages of the conservative GC's pool
 * pagetables to the OS via `munlock -> madvise(MADV_DONTNEED) ->
 * mlock2(MLOCK_ONFAULT)`, while preserving the process-wide
 * `mlockall(MCL_CURRENT|MCL_FUTURE)` guarantee that wekanode (and
 * ssd_proxy / resources-main) rely on: a scavenged page stays locked and
 * out of RSS until the GC re-carves it, at which point the first touch
 * faults in a zero page that is locked at fault time -- no second fault,
 * no swap exposure, no bookkeeping at the allocation site.
 *
 * This module owns the bookkeeping (per-pool `scavengedMap`, the global
 * dirty-free-page counter, arm/disable state); the call sites live in
 * `impl.conservative.gc` as minimal one-line hooks at every place a page
 * transitions to/from `Bins.B_FREE` or a pool is created/destroyed. The
 * munlock/madvise(DONTNEED)/mlock2(ONFAULT) triple is what lets a page sit
 * out of RSS while still covered by mlockall: the first touch after the GC
 * re-carves it simply faults in a fresh zero page that ONFAULT locks at
 * that exact moment, so no code at the allocation site needs to know a
 * page was ever scavenged.
 *
 * Policy -- whether scavenging is armed at all, and how many bytes to
 * scavenge on any given pass -- is deliberately out of scope for this
 * module. It lives entirely in the consuming application, which drives
 * that pace through the `weka_gc_scavenge` / `weka_gc_scavenger_arm`
 * extern(C) entry points defined at the bottom of `impl.conservative.gc`.
 *
 * Copyright: Weka.IO 2026.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */
module core.internal.gc.scavenger;

version (WEKA):

import core.internal.gc.impl.conservative.gc : Pool, Gcx, Bins, PAGESIZE;
import core.gc.config : config;

/// Status codes returned by `wekaScavengerArm`/`wekaScavengerStatus`.
/// Mirrored 1:1 by the consuming WEKA application -- keep the numeric
/// values stable.
enum Status : int
{
    OK                      = 0,
    NOT_ARMED               = 1,
    DISABLED_DEBUG_BUILD    = 2,
    DISABLED_MLOCK2_ENOSYS  = 3,
    DISABLED_SYSCALL_FAILED = 4,
    DISABLED_MAPS_PRESSURE  = 5, // transient; reported for the last pass only
    DISABLED_BY_CONFIG      = 6, // gcopt scavenge:0
}

// The mechanism itself is Linux-only: dropping a page out of RSS while keeping
// the mlockall() guarantee takes madvise(MADV_DONTNEED) followed immediately by
// mlock2(MLOCK_ONFAULT), and no other platform offers that pair. Elsewhere the
// hooks below are no-ops, so gc.d's call sites and its extern(C) entry points
// stay source-compatible everywhere the compiler itself is built -- notably
// macOS, where this fork also builds druntime with version=WEKA.
version (linux) {} else
{
    void wekaScavengerOnPoolCreate(Pool*) nothrow @nogc {}
    void wekaScavengerOnPoolDestroy(Pool*) nothrow @nogc {}
    void wekaScavengerOnPagesFreed(Pool*, size_t, size_t) nothrow @nogc {}
    void wekaScavengerOnPagesCarved(Pool*, size_t, size_t) nothrow @nogc {}
    size_t wekaScavengerPass(Gcx*, size_t) nothrow @nogc { return 0; }
    size_t wekaScavengerDirtyFreeBytes() nothrow @nogc { return 0; }
    void wekaScavengerInjectFail(int) nothrow @nogc {}

    // Reported as never-armed rather than as a distinct "unsupported platform"
    // code: the status values are mirrored by the consuming application, and a
    // process that cannot scavenge is indistinguishable from one that never
    // armed.
    int wekaScavengerArm(Gcx*, bool) nothrow @nogc { return Status.NOT_ARMED; }
    int wekaScavengerStatus() nothrow @nogc { return Status.NOT_ARMED; }
}

version (linux):

import core.sys.linux.sys.mman : madvise, MADV_DONTNEED, MADV_NOHUGEPAGE;
import core.sys.posix.sys.mman : mlock, munlock;
import core.stdc.errno : errno, ENOSYS;
import core.stdc.string : memset;
static import cstdlib = core.stdc.stdlib;

// Compiled out entirely under the debug versions that either write patterns
// into freed memory or track it via shadow memory -- MADV_DONTNEED would
// zero it out from under them / desync the shadow state.
debug (MEMSTOMP)
    private enum compiledOut = true;
else debug (SENTINEL)
    private enum compiledOut = true;
else debug (VALGRIND)
    private enum compiledOut = true;
else
    private enum compiledOut = false;

// Below this, syscall and VMA churn isn't worth it. Expressed in bytes and converted with the GC's own
// PAGESIZE rather than assuming 4K, so it stays 64KB whatever the pool page size is.
private enum MIN_RUN_BYTES = 64 * 1024;
private enum MIN_RUN_PAGES = MIN_RUN_BYTES / PAGESIZE;
private enum MLOCK_ONFAULT = 1;
private enum MAP_COUNT_HEADROOM_NUM = 9;  // stop a pass above 90% of vm.max_map_count
private enum MAP_COUNT_HEADROOM_DEN = 10;

// Mutated only under the GC lock: the hooks run inside gc.d with the lock already held, and every
// extern(C) entry point that writes takes ConservativeGC.lockNR() the way minimize() does. The status and
// dirty-bytes readers, and the test-only fail injector, are deliberately lock-free -- a stale read of a
// counter or a status code is harmless.
private
{
    __gshared size_t g_dirtyFreePages;   // pages with B_FREE && !scavenged, across all pools
    __gshared bool   g_armed;
    __gshared bool   g_heapMlocked;      // process ran mlockall(MCL_CURRENT|MCL_FUTURE)
    __gshared bool   g_stickyDisabled;
    __gshared int    g_status = Status.NOT_ARMED;
    __gshared size_t g_poolCursor;        // rotates which pool a pass starts scanning from
    __gshared int    g_injectFailMode;    // test hook: 0=off, 1=next madvise(DONTNEED) fails, 2=next mlock2 fails

    version (X86_64)
        enum SYS_mlock2 = 325;
    else version (AArch64)
        enum SYS_mlock2 = 284;
    else
        static assert(false, "weka scavenger: mlock2 syscall number not known for this architecture");

    extern (C) long syscall(long number, ...) nothrow @nogc;

    // mlock2() has no druntime binding anywhere (checked core.sys.{posix,linux}.sys.mman);
    // go straight to the raw syscall, matching the glibc wrapper's -1/errno convention.
    int mlock2(const scope void* addr, size_t len, int flags) nothrow @nogc
    {
        if (g_injectFailMode == 2)
        {
            g_injectFailMode = 0;
            return -1;
        }
        return cast(int) syscall(cast(long) SYS_mlock2, addr, len, flags);
    }

    // Routes madvise(DONTNEED) through the inject_fail test hook; NOHUGEPAGE
    // calls are unaffected (best-effort/advisory, never on the failure path).
    int wekaMadvise(void* addr, size_t len, int advice) nothrow @nogc
    {
        if (advice == MADV_DONTNEED && g_injectFailMode == 1)
        {
            g_injectFailMode = 0;
            return -1;
        }
        return madvise(addr, len, advice);
    }

    // Clamped decrement: a transient inconsistency that ever tried to
    // decrement past 0 would otherwise wrap a size_t to ~2^64 and leave the
    // dirty-free gauge reporting garbage forever (the consuming WEKA
    // application's policy divides against it) instead of a bounded glitch.
    void decrementDirtyFreePages(size_t n) nothrow @nogc
    {
        g_dirtyFreePages = g_dirtyFreePages >= n ? g_dirtyFreePages - n : 0;
    }

    // scavengedMap semantics: one byte per page. Nonzero = the page's contents
    // were discarded (madvised away, or provably never resident) -- not counted
    // in g_dirtyFreePages. Zero = dirty: resident-while-free, or carved/live
    // (carved pages are always zero). Only meaningful while the pagetable entry
    // is B_FREE.
    pragma(inline, true)
    bool isMarkedScavenged(const(Pool)* pool, size_t pn) nothrow @nogc
    {
        return pool.scavengedMap[pn] != 0;
    }

    pragma(inline, true)
    void markScavenged(Pool* pool, size_t pn) nothrow @nogc
    {
        pool.scavengedMap[pn] = 1;
    }

    pragma(inline, true)
    void clearScavengedMark(Pool* pool, size_t pn) nothrow @nogc
    {
        pool.scavengedMap[pn] = 0;
    }

    void allocScavengedMap(Pool* pool) nothrow @nogc
    {
        if (pool.scavengedMap !is null)
        {
            return; // already allocated (re-entrant call, or hook invoked twice defensively)
        }
        pool.scavengedMap = cast(ubyte*) cstdlib.malloc(pool.npages);
        // OOM: leave null. The pool becomes untracked -- never counted, never
        // scavenged -- which degrades gracefully instead of crashing the GC.
    }

    // Best-effort attempt to restore the mlockall(MCL_CURRENT|MCL_FUTURE)
    // guarantee after a failed step leaves a range unlocked. Tries the
    // ONFAULT variant first (cheap, matches scavenger intent); falls back to
    // a plain (prefaulting) mlock() so the range is at least locked again.
    void relockBestEffort(void* addr, size_t len) nothrow @nogc
    {
        if (mlock2(addr, len, MLOCK_ONFAULT) != 0)
        {
            mlock(addr, len);
        }
    }

    // Normalizes one pool's VM flags to match the current mlocked state and
    // (re)initializes its scavengedMap accordingly. Used both by
    // wekaScavengerOnPoolCreate (fresh pools, `freshPool = true`) and
    // wekaScavengerArm (existing pools at arm time, `freshPool = false`).
    // Returns false iff the scavenger got sticky-disabled while normalizing
    // this pool (munlock/mlock2 failure).
    //
    // CLEAN(1) is only correct for a genuinely fresh, never-mlocked pool --
    // its pages are provably never faulted. Every other case (a fresh
    // mlocked pool, whose pages MCL_FUTURE already prefaulted; or an
    // existing pool at arm time, whose B_FREE pages likely carry real usage
    // history regardless of lock state) treats them as DIRTY(0). This can
    // over-count pages that were in fact never faulted (e.g. the never-
    // touched tail of a pool at arm time); the over-count is accepted --
    // it self-corrects on the first no-op scavenge of those pages, which
    // finds nothing resident to reclaim and marks them CLEAN from there on.
    bool normalizeAndTrackPool(Pool* pool, bool freshPool) nothrow @nogc
    {
        allocScavengedMap(pool);
        if (pool.scavengedMap is null)
        {
            return true; // degrade gracefully: untracked pool, not a failure
        }

        auto addr = pool.baseAddr;
        auto len = pool.npages * PAGESIZE;

        // Advisory only -- a failure here doesn't compromise correctness, it just means THP interaction
        // is whatever it was before. A THP-backed pool cannot be released a page at a time, so turning
        // this off (gcopt scavengeNoHugePages:0) largely defeats scavenging on a THP=always host.
        if (config.scavengeNoHugePages)
        {
            wekaMadvise(addr, len, MADV_NOHUGEPAGE);
        }

        bool failed;
        if (g_heapMlocked)
        {
            if (munlock(addr, len) != 0 || mlock2(addr, len, MLOCK_ONFAULT) != 0)
            {
                relockBestEffort(addr, len);
                g_status = Status.DISABLED_SYSCALL_FAILED;
                g_stickyDisabled = true;
                failed = true;
                // Fall through to the same map init as the success path: with
                // g_heapMlocked true here, that's always DIRTY(0) -- giving
                // up on this pool's lock state doesn't mean giving up on the
                // "carved pages are always 0" invariant onPagesFreed's debug
                // assert relies on, and once sticky-disabled nothing will
                // ever act on this map for scavenging again anyway.
            }
        }

        immutable clean = freshPool && !g_heapMlocked;
        // 1 = marked-scavenged (clean, never faulted); 0 = dirty -- see
        // isMarkedScavenged/markScavenged above.
        memset(pool.scavengedMap, clean ? 1 : 0, pool.npages);
        return !failed;
    }

    // The munlock -> madvise(DONTNEED) -> mlock2(ONFAULT) triple for one run
    // of already-verified dirty-free pages. Sticky-disables on any failure.
    bool scavengeRun(void* addr, size_t len) nothrow @nogc
    {
        if (g_heapMlocked && munlock(addr, len) != 0)
        {
            // Nothing touched yet -- no relock needed.
            g_status = Status.DISABLED_SYSCALL_FAILED;
            g_stickyDisabled = true;
            return false;
        }

        if (wekaMadvise(addr, len, MADV_DONTNEED) != 0)
        {
            if (g_heapMlocked)
            {
                relockBestEffort(addr, len);
            }
            g_status = Status.DISABLED_SYSCALL_FAILED;
            g_stickyDisabled = true;
            return false;
        }

        if (g_heapMlocked && mlock2(addr, len, MLOCK_ONFAULT) != 0)
        {
            relockBestEffort(addr, len);
            g_status = Status.DISABLED_SYSCALL_FAILED;
            g_stickyDisabled = true;
            return false;
        }

        return true;
    }

    // Scans one pool's pagetable for maximal dirty-free runs and scavenges
    // them (min-run filtered) until `maxBytes` is spent. Returns bytes
    // actually scavenged; stops immediately (returning what's scavenged so
    // far) if a syscall failure sticky-disables the scavenger mid-pool.
    size_t scavengePool(Pool* pool, size_t maxBytes) nothrow @nogc
    {
        if (pool.scavengedMap is null)
        {
            return 0;
        }

        size_t scavenged;
        size_t pn;
        while (pn < pool.npages && scavenged < maxBytes)
        {
            if (pool.pagetable[pn] != Bins.B_FREE || isMarkedScavenged(pool, pn))
            {
                ++pn;
                continue;
            }

            immutable runStart = pn;
            while (pn < pool.npages && pool.pagetable[pn] == Bins.B_FREE && !isMarkedScavenged(pool, pn))
            {
                ++pn;
            }
            size_t runLen = pn - runStart;

            if (runLen < MIN_RUN_PAGES)
            {
                continue; // pn already advanced past the short run
            }

            if (scavenged + runLen * PAGESIZE > maxBytes)
            {
                immutable allowedPages = (maxBytes - scavenged) / PAGESIZE;
                if (allowedPages < MIN_RUN_PAGES)
                {
                    break; // not enough budget left for a worthwhile run
                }
                runLen = allowedPages;
            }

            auto runAddr = pool.baseAddr + runStart * PAGESIZE;
            if (!scavengeRun(runAddr, runLen * PAGESIZE))
            {
                return scavenged; // sticky-disabled inside scavengeRun(); stop the whole pass
            }

            foreach (i; runStart .. runStart + runLen)
            {
                markScavenged(pool, i);
            }
            decrementDirtyFreePages(runLen);
            scavenged += runLen * PAGESIZE;
        }

        return scavenged;
    }

    // munlock()/mlock2() on a sub-range of a pool's VMA can transiently split
    // it into as many as three VMAs (before/during/after the touched range)
    // until the kernel re-merges them once flags become uniform again; each
    // split consumes an extra vm.max_map_count entry. Close to the ceiling,
    // the split itself can fail with ENOMEM mid-munlock/mlock2 -- which would
    // sticky-disable the scavenger on what is really a transient condition --
    // and a process already at the map limit starts failing unrelated
    // mmap() calls too. So: refuse to even start a pass without headroom
    // rather than find out mid-run. The resulting DISABLED_MAPS_PRESSURE
    // status is transient (not sticky) and re-checked every pass; if /proc
    // is unreadable this fails open (returns false) so a broken /proc mount
    // doesn't permanently block scavenging.
    bool mapCountUnderPressure() nothrow @nogc
    {
        immutable maxMapCount = readIntFile("/proc/sys/vm/max_map_count\0".ptr);
        if (maxMapCount <= 0)
        {
            return false; // couldn't read -- fail open rather than block scavenging on missing /proc
        }

        immutable mapCount = countLines("/proc/self/maps\0".ptr);
        return mapCount * MAP_COUNT_HEADROOM_DEN > cast(size_t) maxMapCount * MAP_COUNT_HEADROOM_NUM;
    }

    long readIntFile(const(char)* path) nothrow @nogc
    {
        import core.sys.posix.fcntl : open, O_RDONLY;
        import core.sys.posix.unistd : read, close;

        int fd = open(path, O_RDONLY);
        if (fd < 0)
        {
            return -1;
        }
        scope (exit) close(fd);

        char[32] buf = void;
        auto n = read(fd, buf.ptr, buf.length);
        if (n <= 0)
        {
            return -1;
        }

        long val = 0;
        foreach (c; buf[0 .. n])
        {
            if (c < '0' || c > '9')
            {
                break;
            }
            val = val * 10 + (c - '0');
        }
        return val;
    }

    size_t countLines(const(char)* path) nothrow @nogc
    {
        import core.sys.posix.fcntl : open, O_RDONLY;
        import core.sys.posix.unistd : read, close;

        int fd = open(path, O_RDONLY);
        if (fd < 0)
        {
            return 0;
        }
        scope (exit) close(fd);

        char[4096] buf = void;
        size_t lines;
        for (;;)
        {
            auto n = read(fd, buf.ptr, buf.length);
            if (n <= 0)
            {
                break;
            }
            foreach (c; buf[0 .. n])
            {
                if (c == '\n')
                {
                    ++lines;
                }
            }
        }
        return lines;
    }
}

// ============================================================================
// Public API -- consumed by impl.conservative.gc's hook call sites and
// extern(C) entry points.
// ============================================================================

/// Pool creation hook: `Pool.initialize`, after npages/freepages are set.
void wekaScavengerOnPoolCreate(Pool* pool) nothrow @nogc
{
    static if (compiledOut)
    {
        pool.scavengedMap = null;
    }
    else
    {
        // os_mem_map() failed: initialize() zeroes npages/leaves baseAddr
        // null in that case. Nothing to map or lock-dance; a 0-length
        // munlock/mlock2 call would be pure risk for zero benefit.
        if (pool.npages == 0)
        {
            pool.scavengedMap = null;
            return;
        }

        if (!g_armed)
        {
            allocScavengedMap(pool);
            if (pool.scavengedMap !is null)
            {
                // 1 = every page of this new pool starts marked-scavenged (never faulted).
                memset(pool.scavengedMap, 1, pool.npages);
            }
            return;
        }

        // A freshly created pool is 100% B_FREE; if the heap is mlocked,
        // MCL_FUTURE has already prefaulted it resident (normalizeAndTrackPool
        // marks the map DIRTY(0) in that case, CLEAN(1) otherwise).
        if (normalizeAndTrackPool(pool, /* freshPool = */ true)
            && pool.scavengedMap !is null && g_heapMlocked)
        {
            g_dirtyFreePages += pool.npages;
        }
    }
}

/// Pool destruction hook: `Pool.Dtor`, before anything else in the function
/// (in particular before `pagetable` is freed and before `os_mem_unmap`).
void wekaScavengerOnPoolDestroy(Pool* pool) nothrow @nogc
{
    static if (!compiledOut)
    {
        if (pool.scavengedMap is null)
        {
            return;
        }

        size_t dirty;
        foreach (pn; 0 .. pool.npages)
        {
            if (pool.pagetable[pn] == Bins.B_FREE && !isMarkedScavenged(pool, pn))
            {
                ++dirty;
            }
        }
        decrementDirtyFreePages(dirty);

        cstdlib.free(pool.scavengedMap);
        pool.scavengedMap = null;
    }
}

/// Hook for every place `npages` pages starting at `pagenum` transition to
/// `Bins.B_FREE`: sweep's large-object branch, sweep's small-object
/// recoverPage branch, and `LargeObjectPool.freePages` (which alone covers
/// reallocNoSync's shrink path, freeNoSync's large-object path, and
/// runFinalizers -- all three call through it).
///
/// A carved page's map bit is always 0 (DIRTY) by the carve-hook's own
/// invariant, so freeing never needs to read or write the map -- only bump
/// the counter.
void wekaScavengerOnPagesFreed(Pool* pool, size_t pagenum, size_t npages) nothrow @nogc
{
    static if (!compiledOut)
    {
        if (pool.scavengedMap is null)
        {
            return;
        }

        debug
        {
            foreach (pn; pagenum .. pagenum + npages)
            {
                assert(!isMarkedScavenged(pool, pn), "carved pages must stay DIRTY in the scavenged map");
            }
        }

        g_dirtyFreePages += npages;
    }
}

/// Hook for every place `npages` pages starting at `pagenum` are carved out
/// of `Bins.B_FREE`: `SmallObjectPool.allocPage`, `LargeObjectPool.allocPages`,
/// `Gcx.extendNoSync`, and `Gcx.reallocNoSync`'s expand-in-place path.
void wekaScavengerOnPagesCarved(Pool* pool, size_t pagenum, size_t npages) nothrow @nogc
{
    static if (!compiledOut)
    {
        if (pool.scavengedMap is null)
        {
            return;
        }

        foreach (pn; pagenum .. pagenum + npages)
        {
            if (isMarkedScavenged(pool, pn))
            {
                clearScavengedMark(pool, pn); // was clean-free, no counter change
            }
            else
            {
                decrementDirtyFreePages(1); // was dirty-free, now consumed
            }
        }
    }
}

/// One-time arm: capability-probes mlock2 (if `heapIsMlocked`), normalizes
/// every existing pool, and counts every existing B_FREE page as dirty-free.
/// This over-counts a pool's never-touched tail (pages that are mapped but
/// were never actually faulted in, so they're already effectively clean);
/// the over-count is accepted -- it self-corrects on the first no-op
/// scavenge of those pages. Assumes the caller holds the GC lock.
int wekaScavengerArm(Gcx* gcx, bool heapIsMlocked) nothrow @nogc
{
    static if (compiledOut)
        return Status.DISABLED_DEBUG_BUILD;
    else
    {
        if (g_armed)
        {
            return g_status; // one-time; already armed, report current status
        }

        if (!config.scavenge)
        {
            g_status = Status.DISABLED_BY_CONFIG;
            g_stickyDisabled = true;
            return g_status;
        }

        if (heapIsMlocked && mlock2(null, 0, MLOCK_ONFAULT) != 0 && errno == ENOSYS)
        {
            g_status = Status.DISABLED_MLOCK2_ENOSYS;
            g_stickyDisabled = true;
            return g_status;
        }

        g_heapMlocked = heapIsMlocked;

        // Authoritative from here: pools created before this arm() call may
        // already have driven onPagesFreed/onPagesCarved (their map/counter
        // updates are otherwise-harmless bookkeeping against an unarmed,
        // never-scavenged state -- see wekaScavengerOnPoolCreate). Discard
        // whatever that pre-arm history left in the counter and recompute it
        // from the ground truth (pagetable[]) below, once per pool.
        g_dirtyFreePages = 0;

        foreach (pool; gcx.pooltable[])
        {
            if (!normalizeAndTrackPool(pool, /* freshPool = */ false))
            {
                return g_status; // sticky-disabled inside; stop arming further pools
            }

            if (pool.scavengedMap !is null)
            {
                foreach (pn; 0 .. pool.npages)
                {
                    if (pool.pagetable[pn] == Bins.B_FREE)
                    {
                        ++g_dirtyFreePages;
                    }
                }
            }
        }

        g_armed = true;
        g_status = Status.OK;
        return g_status;
    }
}

/// Scavenges up to `maxBytes` worth of dirty-free pages across all pools,
/// resuming from a rotating pool cursor so consecutive passes don't always
/// restart at pool 0. Assumes the caller holds the GC lock. Returns 0 if
/// unarmed, sticky-disabled, or under map-count pressure this pass.
size_t wekaScavengerPass(Gcx* gcx, size_t maxBytes) nothrow @nogc
{
    static if (compiledOut)
        return 0;
    else
    {
        if (!g_armed || g_stickyDisabled)
        {
            return 0;
        }

        if (mapCountUnderPressure())
        {
            g_status = Status.DISABLED_MAPS_PRESSURE; // transient: not sticky, re-checked next pass
            return 0;
        }
        g_status = Status.OK;

        auto pools = gcx.pooltable[];
        if (pools.length == 0)
        {
            return 0;
        }
        if (g_poolCursor >= pools.length)
        {
            g_poolCursor = 0;
        }

        size_t scavenged;
        foreach (offset; 0 .. pools.length)
        {
            if (maxBytes - scavenged < MIN_RUN_PAGES * PAGESIZE)
            {
                break;
            }

            auto pool = pools[(g_poolCursor + offset) % pools.length];
            scavenged += scavengePool(pool, maxBytes - scavenged);

            if (g_stickyDisabled)
            {
                break;
            }
        }
        g_poolCursor = (g_poolCursor + 1) % pools.length;

        return scavenged;
    }
}

/// `g_dirtyFreePages * PAGESIZE`. Lock-free read of a counter mutated only
/// under the GC lock -- fine for a monitoring gauge (same tolerance as
/// other unguarded gshared GC stat counters, e.g. `Gcx.mappedPages`).
size_t wekaScavengerDirtyFreeBytes() nothrow @nogc
{
    static if (compiledOut)
        return 0;
    else
        return g_dirtyFreePages * PAGESIZE;
}

/// Current status/disabled-reason. See `Status` above.
int wekaScavengerStatus() nothrow @nogc
{
    static if (compiledOut)
        return Status.DISABLED_DEBUG_BUILD;
    else
        return g_status;
}

/// Test hook: force the next madvise(DONTNEED) (mode 1) or mlock2 (mode 2)
/// call to behave as failed, to exercise the sticky-disable path
/// end-to-end. 0 turns injection off.
void wekaScavengerInjectFail(int mode) nothrow @nogc
{
    g_injectFailMode = mode;
}

static if (!compiledOut)
unittest
{
    import core.memory : GC;
    import core.internal.gc.impl.conservative.gc :
        weka_gc_scavenge, weka_gc_scavenger_arm, weka_gc_dirty_free_bytes, weka_gc_scavenger_status;

    if (weka_gc_scavenger_status() == Status.DISABLED_DEBUG_BUILD)
    {
        return; // kept for symmetry with the consuming WEKA application's own runtime unittest guard
    }

    enum size_t allocSize = 4 * 1024 * 1024; // comfortably above MIN_RUN_PAGES once freed
    auto p = GC.malloc(allocSize, GC.BlkAttr.NO_SCAN);
    GC.free(p);
    GC.collect();

    immutable armStatus = weka_gc_scavenger_arm(0 /* heapIsMlocked */);
    if (armStatus != Status.OK)
    {
        return; // e.g. mlock2 genuinely unavailable in this test environment
    }

    immutable dirtyBefore = weka_gc_dirty_free_bytes();
    assert(dirtyBefore > 0, "the freed allocation should be counted as dirty-free after collection+arm");

    immutable scavenged = weka_gc_scavenge(size_t.max);
    assert(scavenged > 0, "scavenge should reclaim the freed run");
    assert(weka_gc_dirty_free_bytes() < dirtyBefore, "dirty-free counter should shrink after a successful scavenge");
}
