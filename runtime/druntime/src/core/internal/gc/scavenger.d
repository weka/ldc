/**
 * Page-level scavenger for the conservative GC.
 *
 * Returns whole free (`Bins.B_FREE`) pages of the GC's pools to the OS with
 * `madvise(MADV_DONTNEED)`. This covers the case `minimize()` alone cannot:
 * unmapping a pool requires it to be 100% free, so a long-lived process whose
 * heap grew once and then freed most of it keeps paying for that peak in RSS
 * forever, however much of each pool is free.
 *
 * On a heap the process has mlocked (`mlockall(MCL_CURRENT|MCL_FUTURE)`, or an
 * explicit `mlock` over the heap) plain `madvise` is refused, so the sequence
 * becomes `munlock -> madvise(MADV_DONTNEED) -> mlock2(MLOCK_ONFAULT)`. That
 * preserves the lock guarantee while still dropping the pages: a scavenged page
 * stays locked and out of RSS until the GC re-carves it, at which point the
 * first touch faults in a zero page that is locked at fault time -- no second
 * fault, no swap exposure, and nothing for the allocation site to know about.
 *
 * This module owns the bookkeeping (per-pool `scavengedMap`, the global
 * dirty-free-page counter, arm/disable state); the call sites live in
 * `core.internal.gc.impl.conservative.gc` as one-line hooks wherever a page
 * transitions to or from `Bins.B_FREE` and wherever a pool is created or
 * destroyed.
 *
 * Scavenging is off unless enabled through `gcopt` (see `core.gc.config`), and
 * is a no-op outside Linux: dropping a page out of RSS while keeping an mlock
 * guarantee takes `madvise(MADV_DONTNEED)` followed immediately by
 * `mlock2(MLOCK_ONFAULT)`, and no other platform offers that pair.
 *
 * Copyright: D Language Foundation 2026.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Baruch Even
 */
module core.internal.gc.scavenger;

import core.internal.gc.impl.conservative.gc : Pool, Gcx, Bins, PAGESIZE;
import core.gc.config : config;

/// Status codes reported by `scavengerArm`/`scavengerStatus`.
enum ScavengeStatus : int
{
    OK                      = 0,
    NOT_ARMED               = 1,
    DISABLED_DEBUG_BUILD    = 2,
    DISABLED_MLOCK2_ENOSYS  = 3,
    DISABLED_SYSCALL_FAILED = 4,
    DISABLED_MAPS_PRESSURE  = 5, // transient; reported for the last pass only
    DISABLED_BY_CONFIG      = 6, // gcopt scavenge:0
    DISABLED_PAGE_SIZE_MISMATCH = 7, // kernel page size is not the GC's PAGESIZE -- see scavengerArm
}

// Linux-only mechanism -- see the module documentation. Everywhere else the hooks below are no-ops, so
// gc.d's call sites stay source-compatible on every target for the price of one null pointer per pool.
version (linux) {} else
{
    void scavengerOnPoolCreate(Pool*) nothrow @nogc {}
    void scavengerOnPoolDestroy(Pool*) nothrow @nogc {}
    void scavengerOnPagesFreed(Pool*, size_t, size_t) nothrow @nogc {}
    void scavengerOnPagesCarved(Pool*, size_t, size_t) nothrow @nogc {}
    size_t scavengerPass(Gcx*, size_t) nothrow @nogc { return 0; }
    void scavengerMinimizePhase(Gcx*) nothrow @nogc {}
    size_t scavengerDirtyFreeBytes() nothrow @nogc { return 0; }

    // Reported as never-armed rather than as a distinct "unsupported platform" code: to every caller a
    // process that cannot scavenge is indistinguishable from one that never armed.
    int scavengerArm(Gcx*, bool) nothrow @nogc { return ScavengeStatus.NOT_ARMED; }
    int scavengerStatus() nothrow @nogc { return ScavengeStatus.NOT_ARMED; }
}

version (linux):

import core.sys.linux.sys.mman : madvise, MADV_DONTNEED, MADV_NOHUGEPAGE;
import core.sys.posix.sys.mman : mlock, munlock;
import core.stdc.errno : errno, ENOSYS, EINVAL;
import core.sys.posix.unistd : _SC_PAGESIZE;
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

// Mutated only under the GC lock: the hooks run inside gc.d with the lock already held, and so does the
// minimize() phase. The status and counter readers are deliberately lock-free -- a stale read of a gauge or
// of a status code is harmless.
private
{
    __gshared size_t g_dirtyFreePages;   // pages with B_FREE && !scavenged, across all pools
    __gshared bool   g_armed;
    __gshared bool   g_heapMlocked;      // process ran mlockall(MCL_CURRENT|MCL_FUTURE)
    __gshared bool   g_stickyDisabled;
    __gshared int    g_status = ScavengeStatus.NOT_ARMED;
    __gshared size_t g_poolCursor;        // rotates which pool a pass starts scanning from
    __gshared bool   g_lockedDetected;    // madvise said EINVAL: the heap is locked, switch modes and retry
    __gshared size_t g_kernelPageSize = PAGESIZE; // madvise/mlock2 granularity; see scavengePool
    __gshared long   g_maxMapCount;       // vm.max_map_count, read once: 0 = not yet read, -1 = unreadable

    // mlock2() has no druntime binding (checked core.sys.{posix,linux}.sys.mman), so it is issued as a raw
    // syscall and the number has to be known per architecture. Where it is not, only the locked-heap
    // sequence is unavailable: a process whose heap is not mlocked never calls mlock2 and scavenges as usual.
    version (X86_64)
        enum SYS_mlock2 = 325;
    else version (AArch64)
        enum SYS_mlock2 = 284;
    else
        enum SYS_mlock2 = -1;

    enum haveMlock2 = SYS_mlock2 >= 0;

    extern (C) long syscall(long number, ...) nothrow @nogc;

    // Declared here with explicit attributes, like syscall above, rather than imported: the posix binding
    // does not carry nothrow/@nogc and this is called from an @nogc arm path.
    extern (C) long sysconf(int name) nothrow @nogc;

    // Matches the glibc wrapper's -1/errno convention. errno is NOT touched when mlock2 is unavailable on
    // this architecture, so callers testing for absence must consult `haveMlock2`, never errno.
    int mlock2(const scope void* addr, size_t len, int flags) nothrow @nogc
    {
        static if (!haveMlock2)
        {
            return -1;
        }
        else
        {
            return cast(int) syscall(cast(long) SYS_mlock2, addr, len, flags);
        }
    }

    // Clamped decrement: a transient inconsistency that ever tried to
    // decrement past 0 would otherwise wrap a size_t to ~2^64 and leave the
    // dirty-free gauge reporting garbage forever, instead of a bounded glitch.
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
    // scavengerOnPoolCreate (fresh pools, `freshPool = true`) and
    // scavengerArm (existing pools at arm time, `freshPool = false`).
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
            cast(void) madvise(addr, len, MADV_NOHUGEPAGE);
        }

        bool failed;
        if (g_heapMlocked)
        {
            if (munlock(addr, len) != 0 || mlock2(addr, len, MLOCK_ONFAULT) != 0)
            {
                relockBestEffort(addr, len);
                g_status = ScavengeStatus.DISABLED_SYSCALL_FAILED;
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
            g_status = ScavengeStatus.DISABLED_SYSCALL_FAILED;
            g_stickyDisabled = true;
            return false;
        }

        if (madvise(addr, len, MADV_DONTNEED) != 0)
        {
            // EINVAL on a range we believe is unlocked is the kernel telling us it is locked after all
            // (mlockall, or someone else's mlock). Ask the pass to switch to the locked sequence and
            // retry -- and note the lock is pre-existing, so re-locking afterwards restores what was
            // there rather than locking memory that wasn't.
            if (!g_heapMlocked && errno == EINVAL)
            {
                g_lockedDetected = true;
                return false;
            }

            if (g_heapMlocked)
            {
                relockBestEffort(addr, len);
            }
            g_status = ScavengeStatus.DISABLED_SYSCALL_FAILED;
            g_stickyDisabled = true;
            return false;
        }

        if (g_heapMlocked && mlock2(addr, len, MLOCK_ONFAULT) != 0)
        {
            relockBestEffort(addr, len);
            g_status = ScavengeStatus.DISABLED_SYSCALL_FAILED;
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
            immutable runLen = pn - runStart;

            // madvise/mlock2 act on whole kernel pages: an unaligned address is refused outright and the
            // length is rounded *up*, which would discard live pages past the end of the run. So work on
            // the kernel-page-aligned interior of the run and leave its edges dirty -- they cost one page
            // each and are picked up whenever the neighbouring run grows to cover them. Where the kernel
            // page is the GC's page (every 4K host) this is arithmetically a no-op.
            immutable mask = g_kernelPageSize - 1;
            auto begin = cast(size_t)(pool.baseAddr + runStart * PAGESIZE);
            auto end = begin + runLen * PAGESIZE;
            begin = (begin + mask) & ~mask;
            end &= ~mask;
            if (end <= begin)
            {
                continue; // the run does not span a whole kernel page; pn is already past it
            }

            size_t len = end - begin;

            // Budget clamp in kernel pages, so what is left is still aligned.
            if (scavenged + len > maxBytes)
            {
                len = (maxBytes - scavenged) & ~mask;
            }

            // Minimum run is checked *after* trimming: before it, a run can clear the bar and then trim
            // away to nothing, which wastes the scan and makes scavengedBytes disagree with the gauge.
            if (len < MIN_RUN_BYTES)
            {
                if (scavenged + MIN_RUN_BYTES > maxBytes)
                {
                    break; // not enough budget left for a worthwhile run
                }
                continue;
            }

            if (!scavengeRun(cast(void*) begin, len))
            {
                return scavenged; // sticky-disabled, or lock detected: either way the pass handles it
            }

            // Mark only what was actually discarded, in GC pages.
            immutable firstPage = (begin - cast(size_t) pool.baseAddr) / PAGESIZE;
            immutable pageCount = len / PAGESIZE;
            foreach (i; firstPage .. firstPage + pageCount)
            {
                markScavenged(pool, i);
            }
            decrementDirtyFreePages(pageCount);
            scavenged += len;
        }

        return scavenged;
    }

    // Only relevant to the locked-heap sequence, and only consulted there (see scavengerPass):
    // munlock()/mlock2() on a sub-range of a pool's VMA can transiently split it into as many as three VMAs
    // (before/during/after the touched range) until the kernel re-merges them once flags become uniform
    // again, and each split consumes an extra vm.max_map_count entry. Close to the ceiling the split itself
    // can fail with ENOMEM mid-munlock/mlock2 -- which would sticky-disable the scavenger over what is
    // really a transient condition -- and a process at the map limit starts failing unrelated mmap() calls
    // too. So refuse to start a pass without headroom rather than find out mid-run. The resulting
    // DISABLED_MAPS_PRESSURE status is transient (not sticky) and re-checked every pass.
    //
    // vm.max_map_count is read once and cached: it is a boot/sysctl value, and /proc/self/maps has to be
    // read line by line under the GC lock as it is, so there is no reason to pay for both every pass. An
    // unreadable /proc fails open (never blocks scavenging) and is not retried.
    bool mapCountUnderPressure() nothrow @nogc
    {
        if (g_maxMapCount == 0)
        {
            immutable v = readIntFile("/proc/sys/vm/max_map_count\0".ptr);
            g_maxMapCount = v > 0 ? v : -1;
        }
        if (g_maxMapCount < 0)
        {
            return false; // unreadable -- fail open rather than block scavenging on a missing /proc
        }

        immutable mapCount = countLines("/proc/self/maps\0".ptr);
        return mapCount * MAP_COUNT_HEADROOM_DEN > cast(size_t) g_maxMapCount * MAP_COUNT_HEADROOM_NUM;
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
void scavengerOnPoolCreate(Pool* pool) nothrow @nogc
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
void scavengerOnPoolDestroy(Pool* pool) nothrow @nogc
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
void scavengerOnPagesFreed(Pool* pool, size_t pagenum, size_t npages) nothrow @nogc
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
void scavengerOnPagesCarved(Pool* pool, size_t pagenum, size_t npages) nothrow @nogc
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
int scavengerArm(Gcx* gcx, bool heapIsMlocked) nothrow @nogc
{
    static if (compiledOut)
        return ScavengeStatus.DISABLED_DEBUG_BUILD;
    else
    {
        if (g_armed)
        {
            return g_status; // one-time; already armed, report current status
        }

        if (!config.scavenge)
        {
            g_status = ScavengeStatus.DISABLED_BY_CONFIG;
            g_stickyDisabled = true;
            return g_status;
        }

        // madvise() and mlock2() work in kernel pages: they require a page-aligned address and round the
        // length *up*. The GC's PAGESIZE is a hardcoded 4096, so where the kernel page is larger -- 64KB
        // aarch64 kernels, notably -- a free run is guaranteed neither to start nor to end on a kernel-page
        // boundary. An unaligned start fails EINVAL, which scavengeRun would misread as "the heap is locked
        // after all"; an unaligned end silently discards live pages past the run. Refuse to arm until runs
        // are trimmed to the kernel-page-aligned interior.
        //
        // Runs are trimmed to this granularity in scavengePool, so it only has to be known, not matched.
        // A sysconf failure (-1), or anything below the GC's own page, still disables: the consequence of
        // guessing this wrong is discarding live memory, so it fails closed.
        immutable kernelPageSize = sysconf(_SC_PAGESIZE);
        if (kernelPageSize < PAGESIZE || (kernelPageSize & (kernelPageSize - 1)) != 0)
        {
            g_status = ScavengeStatus.DISABLED_PAGE_SIZE_MISMATCH;
            g_stickyDisabled = true;
            return g_status;
        }
        g_kernelPageSize = cast(size_t) kernelPageSize;

        if (heapIsMlocked && (!haveMlock2 || (mlock2(null, 0, MLOCK_ONFAULT) != 0 && errno == ENOSYS)))
        {
            g_status = ScavengeStatus.DISABLED_MLOCK2_ENOSYS;
            g_stickyDisabled = true;
            return g_status;
        }

        g_heapMlocked = heapIsMlocked;

        // Authoritative from here: pools created before this arm() call may
        // already have driven onPagesFreed/onPagesCarved (their map/counter
        // updates are otherwise-harmless bookkeeping against an unarmed,
        // never-scavenged state -- see scavengerOnPoolCreate). Discard
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
        g_status = ScavengeStatus.OK;
        return g_status;
    }
}

/// Scavenges up to `maxBytes` worth of dirty-free pages across all pools,
/// resuming from a rotating pool cursor so consecutive passes don't always
/// restart at pool 0. Assumes the caller holds the GC lock. Returns 0 if
/// unarmed, sticky-disabled, or under map-count pressure this pass.
// Promotes the process to the locked-heap sequence after madvise reported EINVAL, and re-normalizes every
// pool so their lock flags are uniform again -- otherwise later per-run munlock/mlock2 keeps splitting VMAs
// that the kernel would have merged, burning vm.max_map_count entries.
private bool switchToLockedHeap(Gcx* gcx) nothrow @nogc
{
    g_lockedDetected = false;

    if (!haveMlock2 || (mlock2(null, 0, MLOCK_ONFAULT) != 0 && errno == ENOSYS))
    {
        g_status = ScavengeStatus.DISABLED_MLOCK2_ENOSYS;
        g_stickyDisabled = true;
        return false;
    }

    g_heapMlocked = true;

    foreach (pool; gcx.pooltable[])
    {
        if (!normalizeAndTrackPool(pool, /* freshPool = */ false))
        {
            return false; // sticky-disabled inside
        }
    }

    return true;
}

size_t scavengerPass(Gcx* gcx, size_t maxBytes) nothrow @nogc
{
    static if (compiledOut)
        return 0;
    else
    {
        // Arm on first use so a caller only has to enable the feature, not sequence it. Arming assumes an
        // unlocked heap: that way nothing is mlocked that wasn't already, and if the heap turns out to be
        // locked the first madvise says so (EINVAL) and switchToLockedHeap() promotes us.
        if (!g_armed && scavengerArm(gcx, /* heapIsMlocked = */ false) != ScavengeStatus.OK)
        {
            return 0;
        }

        if (g_stickyDisabled)
        {
            return 0;
        }

        // Only the locked-heap sequence can split VMAs -- munlock/mlock2 change flags on a sub-range,
        // while madvise(MADV_DONTNEED) changes none. An unlocked heap therefore cannot approach the
        // map-count ceiling, and does not pay to read /proc/self/maps on every pass.
        if (g_heapMlocked && mapCountUnderPressure())
        {
            g_status = ScavengeStatus.DISABLED_MAPS_PRESSURE; // transient: not sticky, re-checked next pass
            return 0;
        }
        g_status = ScavengeStatus.OK;

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
        // At most two laps: the second only happens if the first discovered the heap is locked, which can
        // only be discovered once per process.
        foreach (lap; 0 .. 2)
        {
            foreach (offset; 0 .. pools.length)
            {
                if (maxBytes - scavenged < MIN_RUN_PAGES * PAGESIZE)
                {
                    break;
                }

                auto pool = pools[(g_poolCursor + offset) % pools.length];
                scavenged += scavengePool(pool, maxBytes - scavenged);

                if (g_stickyDisabled || g_lockedDetected)
                {
                    break;
                }
            }

            if (!g_lockedDetected || !switchToLockedHeap(gcx))
            {
                break;
            }
        }
        g_poolCursor = (g_poolCursor + 1) % pools.length;

        return scavenged;
    }
}

/// The scavenge phase of minimize(), called once the whole-pool unmap phase is done: the pools that
/// survived it are mostly-free-but-pinned, and their free pages are what page scavenging exists for.
/// Bounded by gcopt scavengeBudget so an existing minimize() caller cannot inherit an unbounded syscall
/// storm -- a caller with more to release calls minimize() again.
void scavengerMinimizePhase(Gcx* gcx) nothrow @nogc
{
    static if (compiledOut)
    {
        return;
    }
    else
    {
        if (!config.scavenge || g_stickyDisabled)
        {
            return;
        }

        // Arm before consulting the counter: until arming recomputes it from the pagetables it only holds
        // whatever the hooks happened to see, which understates a heap that was already free when we
        // started.
        if (!g_armed && scavengerArm(gcx, /* heapIsMlocked = */ false) != ScavengeStatus.OK)
        {
            return;
        }

        if (g_dirtyFreePages * PAGESIZE <= config.scavengeMinFree)
        {
            return;
        }

        cast(void) scavengerPass(gcx, config.scavengeBudget);
    }
}

/// `g_dirtyFreePages * PAGESIZE`. Lock-free read of a counter mutated only under the GC lock -- fine for a
/// monitoring gauge (the same tolerance as other unguarded __gshared GC stat counters, e.g.
/// `Gcx.mappedPages`).
size_t scavengerDirtyFreeBytes() nothrow @nogc
{
    static if (compiledOut)
        return 0;
    else
        return g_dirtyFreePages * PAGESIZE;
}

/// Current status/disabled-reason. See `ScavengeStatus` above.
int scavengerStatus() nothrow @nogc
{
    static if (compiledOut)
        return ScavengeStatus.DISABLED_DEBUG_BUILD;
    else
        return g_status;
}

version (unittest)
{
    // Kept out of the unittest body so the block pointers die with this frame rather than linger in it:
    // the collector scans the stack conservatively, and a retained burst would defeat the test.
    private void allocateBurst(size_t blockSize, size_t blocks, void*[] pinned) nothrow
    {
        import core.memory : GC;

        foreach (i; 0 .. blocks)
        {
            auto p = GC.malloc(blockSize, GC.BlkAttr.NO_SCAN);
            if (i % (blocks / pinned.length) == 0)
            {
                pinned[i / (blocks / pinned.length)] = p;
            }
        }
    }
}

static if (!compiledOut)
unittest
{
    import core.memory : GC;

    if (scavengerStatus() == ScavengeStatus.DISABLED_DEBUG_BUILD)
    {
        return;
    }

    // The phase only runs when enabled and only above its floor: force both, and put them back after.
    immutable savedScavenge = config.scavenge;
    immutable savedMinFree = config.scavengeMinFree;
    config.scavenge = true;
    config.scavengeMinFree = 0;
    scope (exit)
    {
        config.scavenge = savedScavenge;
        config.scavengeMinFree = savedMinFree;
    }

    // Arms the scavenger and drains whatever was already free, so the counter read below is authoritative
    // (before arming it holds only what the hooks happened to see).
    GC.minimize();

    // Pinning one block in eight keeps the pools alive: minimize()'s whole-pool unmap can only take a pool
    // that is 100% free, and were it to take them there would be no free page left for the scavenge phase
    // to find -- the assertions below would then hold without anything having been scavenged.
    enum blockSize = 64 * 1024;  // comfortably above MIN_RUN_BYTES once freed
    enum blocks = 512;           // 32 MB -- big enough that the burst still leaves several MB dirty at
                                 // the final minimize(), whatever earlier collections already drained
    __gshared void*[blocks / 8] pinned;
    allocateBurst(blockSize, blocks, pinned[]);
    GC.collect();

    immutable dirtyBefore = scavengerDirtyFreeBytes();
    assert(dirtyBefore > 0, "the collected blocks should be counted as dirty-free");

    GC.minimize();
    assert(scavengerDirtyFreeBytes() < dirtyBefore, "minimize() should have scavenged dirty-free pages");

    assert(pinned[0] !is null); // keeps the pins observably live past the assertions
}

// The large-kernel-page path, exercised on a 4K host by overriding the granularity. What was wrong before
// trimming was pure arithmetic -- an unaligned madvise start is refused, and the length is rounded up past
// the end of the run, discarding live pages -- so it is worth testing where the kernel that exposes it is
// not available. 64KB is the aarch64 case that matters (RHEL-family arm64 kernels).
static if (!compiledOut)
unittest
{
    import core.memory : GC;

    if (scavengerStatus() == ScavengeStatus.DISABLED_DEBUG_BUILD)
    {
        return;
    }

    immutable savedScavenge = config.scavenge;
    immutable savedMinFree = config.scavengeMinFree;
    config.scavenge = true;
    config.scavengeMinFree = 0;
    scope (exit)
    {
        config.scavenge = savedScavenge;
        config.scavengeMinFree = savedMinFree;
    }

    GC.minimize(); // arm, and drain whatever was already free

    enum kernelPage = 64 * 1024;
    // Deliberately NOT a multiple of the kernel page: 5 GC pages per block means free runs begin and end at
    // arbitrary 4K offsets, which is what gives the trimming something to do. Sizing blocks at 64KB instead
    // makes every run naturally aligned and the test passes with the trimming removed.
    enum blockSize = 5 * PAGESIZE;
    enum blocks = 512;
    enum pinOneIn = 16;                        // runs of 15 blocks = 300KB, so a trimmed interior is 256KB
    __gshared void*[blocks / pinOneIn] pinnedLargePage;
    foreach (i; 0 .. blocks)
    {
        auto p = GC.malloc(blockSize, GC.BlkAttr.NO_SCAN);
        if (i % pinOneIn == 0)
        {
            pinnedLargePage[i / pinOneIn] = p; // keeps the pools off minimize()'s whole-pool unmap path
        }
    }
    GC.collect();

    immutable savedPageSize = g_kernelPageSize;
    g_kernelPageSize = kernelPage;
    scope (exit) g_kernelPageSize = savedPageSize;

    immutable dirtyBefore = g_dirtyFreePages * PAGESIZE;
    assert(dirtyBefore > 0, "the collected blocks should be counted as dirty-free");

    GC.minimize();
    immutable dirtyAfter = g_dirtyFreePages * PAGESIZE;

    // Measured off the gauge rather than a counter so this test sits with the trimming it exercises. The
    // pins keep every pool off minimize()'s whole-pool unmap path, so the only thing that can move the
    // gauge is the scavenge phase.
    assert(dirtyAfter < dirtyBefore, "trimming to kernel pages must still reclaim");
    immutable reclaimed = dirtyBefore - dirtyAfter;
    // The assertion that matters: a reclaim that is not a whole number of kernel pages means the length was
    // rounded, which on a real large-page kernel is how live memory past the run gets discarded.
    assert(reclaimed % kernelPage == 0, "every reclaim must be a whole number of kernel pages");

    assert(pinnedLargePage[0] !is null);
}
