# hg_malloc design

hg_malloc is a memory manager for Kamailio's shared (shm) and private (pkg)
memory, next to fm, qm, tlsf and sm. This document describes its design and
the reasons behind it, as built on the `hg_malloc` branch; the code
comments, one or two lines each, give the local detail. Test results are in
[why-hg-holds.md](why-hg-holds.md).

## Contents

- [1. Overview and goals](#1-overview-and-goals)
- [2. Selection and command line](#2-selection-and-command-line)
- [3. Memory layout](#3-memory-layout)
  - [3.1 Reservation](#31-reservation)
  - [3.2 Page grid and metadata](#32-page-grid-and-metadata)
  - [3.3 Buddy](#33-buddy)
  - [3.4 Size classes, cells and chunks](#34-size-classes-cells-and-chunks)
  - [3.5 Large tier](#35-large-tier)
- [4. Backing tiers and their verification](#4-backing-tiers-and-their-verification)
- [5. Elastic arenas](#5-elastic-arenas)
  - [5.1 Growth on exhaustion](#51-growth-on-exhaustion)
  - [5.2 Three-phase grow](#52-three-phase-grow)
  - [5.3 Growth ahead of demand](#53-growth-ahead-of-demand)
  - [5.4 Reserve floor](#54-reserve-floor)
  - [5.5 Refusals and the grow-blocked latch](#55-refusals-and-the-grow-blocked-latch)
  - [5.6 Shrink: quiet window and drain](#56-shrink-quiet-window-and-drain)
  - [5.7 Interior punch and re-pin](#57-interior-punch-and-re-pin)
  - [5.8 Invariants](#58-invariants)
- [6. Per-thread caches, shared pool and block GC](#6-per-thread-caches-shared-pool-and-block-gc)
  - [6.1 Private caches](#61-private-caches)
  - [6.2 Fast paths](#62-fast-paths)
  - [6.3 Shared pool by blocks, graded by fullness](#63-shared-pool-by-blocks-graded-by-fullness)
  - [6.4 Block GC](#64-block-gc)
- [7. Fork semantics](#7-fork-semantics)
- [8. The sweep and the maintenance process](#8-the-sweep-and-the-maintenance-process)
  - [8.1 The idle-cache sweep](#81-the-idle-cache-sweep)
  - [8.2 The maintenance process](#82-the-maintenance-process)
- [9. Locking rules and invariants](#9-locking-rules-and-invariants)
- [10. Debug checks](#10-debug-checks)
- [11. Statistics, counters and the hg.stats RPC](#11-statistics-counters-and-the-hgstats-rpc)
- [12. Host memory checks](#12-host-memory-checks)
  - [12.1 Host configuration examples](#121-host-configuration-examples)
- [13. File map](#13-file-map)
- [14. Kamailio interfaces hg_malloc relies on](#14-kamailio-interfaces-hg_malloc-relies-on)
- [15. Open questions for review](#15-open-questions-for-review)
- [16. Limitations](#16-limitations)

## 1. Overview and goals

**Goals.** hg_malloc is meant to:

1. **Keep the request path off shared locks.** An allocation, and the free
   that returns it, should touch only the calling thread's own state, also
   where frees come in batches under `shm_global_lock()` (tm) and where
   several threads share one process's pkg memory (the TCP reactor).
2. **Size memory by demand.** Start at a given size, grow to a cap, and give
   quiet memory back, never below the start.
3. **Use huge pages where the host has them, without needing them**, and
   know which backing it got rather than assume it.
4. **Keep page faults off the request path.** Memory is committed before it
   is handed out, and pinned where the host allows.
5. **Fail safe on corruption.** Refuse and report a bad free or a damaged
   header rather than follow it, never hand a cell out twice, and on request
   check the end of every allocation or stop the process.
6. **Leave the other managers alone.** With another manager selected, the
   hooks hg adds to the core do nothing and that manager runs as before;
   only `-m` and `-M` also accept a `k`/`m`/`g` suffix. The load tests
   check this with two binaries, f_malloc and q_malloc in the hg build
   against the same manager in a build without hg_malloc (the "stock build"
   arms of why-hg-holds.md).

**How the design meets them.**

- **No lock on the common path.** An allocation and the free that returns it
  touch only the calling thread's cache, also in a threaded process: with
  `tcp_main_threads=2` the TCP reactor threads of TCP main allocate from its
  pkg arena and from shm at once. On these paths the arena lock is taken
  only to move cells between a cache and the shared pool, to carve or return
  a block, and for the large tier. Under hg `shm_global_lock()` does nothing.
- **Elastic arenas.** `-m INIT:CAP` / `-M INIT:CAP` start at INIT, grow to
  CAP, and give quiet memory back, never below INIT.
- **Verified huge pages.** A THP backing is read back from the kernel's
  counters at reserve and on every span grow, never inferred from kernel
  versions or sysfs; a hugetlb mapping is huge by construction. 4 KB pages
  are the last tier, always available.
- **Resident memory.** Commits are pre-faulted, and pinned where
  `RLIMIT_MEMLOCK` allows.
- **Corruption is refused, not followed.** Each cell header carries a state
  and a checksum; a double free, a damaged header or a foreign pointer is
  logged, counted and refused, and the cell leaks rather than being handed
  out twice. With the core `mem_safety` at 0 the process aborts after the
  log line instead. With `mem_guard` (on by default when memory debugging is
  built in) every new allocation outside the debug variant also carries a
  tail guard, checked at free and realloc (section 10). Exhaustion fails the
  allocation; there is no fallback manager.

There are three kinds of arena, each a `struct hg_block` laid out at the
start of the reservation it manages, so the allocator never allocates
through itself for its own bookkeeping:

| arena | mapping | created | used by |
|---|---|---|---|
| shm | `MAP_SHARED` | at shm init, before the first fork | every process |
| pre-fork pkg | `MAP_PRIVATE`, `HG_INIT_INHERITED` | at pkg init, before the config | the main process; children see it copy-on-write |
| per-process pkg | `MAP_PRIVATE` | first thing in each child | that process and its threads |

Layers: the entry points (`hg_malloc_dyn.h`, memapi signatures); the small
tier (21 classes, cells in blocks, per-thread caches, a shared pool); the
large tier for what does not fit the largest cell; a buddy allocator per
page under both; the backing layer that reserves, commits, releases and
re-pins pages.

## 2. Selection and command line

- `HG_MALLOC` is defined by `src/Makefile.defs` and the cmake option
  `HG_MALLOC` (on); `kamailio -V` lists it.
- `-x hg` (or `hg_malloc`) selects hg for shm, `-X hg` for pkg; `hgdbg` adds
  the checks of section 10. Without `-X`, pkg follows `-x`. Under the memapi
  name `hg_malloc`, `shm_address_in()` defers to hg and
  `tcp_reactor_pkg_lock_install()` installs no reactor pkg mutex.
- `-m`/`-M` take `INIT[:CAP]` in MB or with a `k`, `m` or `g` suffix
  (`ksr_mem_size_arg()`). A CAP needs an hg manager and may not be below
  INIT; without one the arena is fixed. The `-M` cap is per process.
- `mlock_pages` is ignored under hg (with a notice): `mlockall()` would lock
  the whole reserved cap. The core dump limit is computed from the caps.
- Tunables are C globals in `hg_kam.c`; neither the config nor the command
  line sets them.

| global | default | meaning |
|---|---|---|
| `hg_ram_floor_mb` | 0 | host RAM floor; 0 = derived (section 12) |
| `hg_shm_grow_granule`, `hg_pkg_grow_granule` | 0 | grow step; 0 = an eighth of the cap, within one page and 16 MB |
| `hg_lock_stall_us` | 1000 | a lock hold this long is a stall |
| `hg_grow_ahead` | 1 | the headroom rule (5.3) |
| `hg_scaling_cycle` | 30 | seconds per GC and shrink cycle in the maintenance process |
| `hg_shrink_step` | 64 MB | most released per drain step |
| `hg_interior_release` | 0 | interior punch (5.7); off |

The tail guard is the core parameter `mem_guard` (section 10), not one of
these.

## 3. Memory layout

### 3.1 Reservation

`hg_malloc_init()` takes the cap by arena name (`"shm"`: `-m`, `"pkg"`: `-M`)
and picks the page unit (`hg_arena_page()`): the huge page size, probed once
from `Hugepagesize` (`hg_hps()`; 2 MB when unreadable or not a power of two),
because it varies by architecture and page configuration and a wrong value
misaligns the THP tiers and mis-sizes the unmap. When INIT and CAP are both
under one huge page the arena runs in small mode on 256 KB pages
(`HG_SMALL_PAGE`): no huge page can form there, and a page caps every buddy
block, so it must hold the biggest slab chunk (a header and two 64 KB cells). An
INIT under a huge page with a CAP above is settled by the tier obtained: on huge
pages INIT becomes one page (refused when the cap leaves no room above it); on 4
KB pages the grid uses small pages and, on Linux, the rest of the first huge
page is released. The smallest arena (`hg_min_viable()`) is one huge page, or
two small pages (one when it can grow).

The whole cap is reserved as one mapping (on hugetlb, INIT alone when the pool
cannot back the cap, and the arena is fixed); INIT is committed at once, after
`hg_init_fits()` has checked the host can hold it, rather than leave that to the
OOM killer. The block header fills the front; the bump offset `hoff` starts at
the next leaf. `span_end` is the extent of the published grid, `committed_bytes`
what is backed; they differ only while pages are punched (5.7). `hcap`, the
reserved extent, never changes; `committed_min` (INIT) is the shrink floor.
Address tests use `hcap` or `span_end`; figures that count memory use
`committed_bytes`.

### 3.2 Page grid and metadata

`hg_pages_init()` puts page 0 at `pbase`, `hbase` rounded up to the page
(Linux reserve paths are already aligned; the plain mapping used elsewhere
may lose a head). Page and leaf are a shift and a mask from any address. A
mistake there would not fail where made but resolve pointers to the wrong
block, so the arithmetic is checked on real addresses across the grid (five
probes; an unaligned head and the byte past the end must not count as page
memory) and the arena is refused if it fails.

The buddy metadata is one bump carve from the arena front, before the buddy
owns it: page descriptors (`struct hg_page`), the whole-free page bitmap,
and per page a leaf-order array (a byte per leaf) and a node bitmap. It gets
the arena's backing and visibility at no extra pages, and is sized for
`npages_cap`, so a grow only publishes pages and never seeks room for
metadata in a full arena. After `buddy_ready`, `hg_chunk_backing()` refuses
to bump (`HG_C_INTERNAL`): that memory is also free to the buddy. The page
the header and metadata partly fill is freed leaf by leaf through the normal
free path, so the tree is built by the rules that maintain it; those merges
go to `buddy_merges_init`, and `buddy_merges` restarts at zero.

### 3.3 Buddy

One tree per page (`hg_buddy.c`), leaf `HG_LEAF_SIZE` 8 KB (`HG_LEAF_SHIFT`
13; a smaller leaf multiplies the leaf arrays), top order the page
(`hps_shift - HG_LEAF_SHIFT`, 8 on 2 MB pages; `HG_MAX_ORDERS` 24 bounds the
arrays). Merging stops at the page, so a free top block is one page, the
unit returned to the host. Split and merge change records only; nothing live
moves, since callers hold raw pointers.

`leaforder[leaf]` holds the order of the block containing the leaf, on every
leaf of it, so `hg_buddy_block_of()` maps any interior address to its block
with two shifts, a table byte and a mask (`HG_LEAF_NONE` in a run).
`bitmap[node]` is 1 only for a whole free block, the merge question in one
bit. Top-order free blocks are a bitmap of pages (`wfree`), lowest served
first, so carving packs low, the top drains for trimming, and no list node
lives in a page a punch could destroy. Lower orders are LIFO lists linked
through the blocks' first bytes (`struct hg_free_blk`).

- **Allocate** the smallest free order at or above the request, preserving
  large blocks; split down, publishing upper halves, so the address stays.
- **Free** is refused (`HG_C_BUDDY_BAD_FREE`) outside the grid, misaligned,
  off a block start or at an unrecorded order; a double free is caught by the
  bitmap (`HG_C_DOUBLE_FREE`), which the recorded order cannot do. Then merge
  up while the buddy is free and whole.
- **Runs** above a page take contiguous whole-free pages
  (`hg_buddy_alloc_run()`) by a linear scan that skips punched and releasing
  pages; runs are too rare to need an index.
- A list head found on a punched page is refused untouched and the order's
  list rebuilt from the bitmaps.
- Every grid allocation and free calls `hg_reserve_floor_check()` here,
  where slab, large and run allocations all pass, so no consumer can skip
  it.

### 3.4 Size classes, cells and chunks

`cell_sizes[]` holds `HG_NCLASSES` (21) total slot sizes, header included,
from 64 to 65536 bytes, about x1.5 apart, multiples of 32. `size2class[]`
maps a request in `HG_ROUNDTO` steps to the first class holding it plus
`HG_CELL_HDR` (plus `HG_DBG_TAIL` under hgdbg, or `HG_GUARD_ROOM` with the
guard); requests that do not fit
`HG_CELL_MAX` (65536) go to the large tier.

The cell header (`struct hg_cell_hdr`) sits before the payload, since
callers get plain pointers. Its first `HG_ROUNDTO` bytes hold class, state
and a 16-bit checksum as one 32-bit word; `DBG_HG_MALLOC` adds file,
function, line and module. `HG_CELL_HDR` rounds to `HG_PAYLOAD_ALIGN` (8), so
payloads suit 64-bit fields and atomics where `HG_ROUNDTO` is 4; static
asserts pin the layout. A free cell keeps its list link in its payload.

A chunk is one buddy block bound to one class: `struct hg_chunk` (at most
128 bytes, 64-aligned) in its first bytes, cells after it. No side array is
needed and the header shares lines with the block in use; each cell names
its class, so blocks of different classes can share a page.
`chunk_size_for()` aims at `HG_CELLS_PER_BLOCK` (32) cells, at least a leaf,
at most `chunk_max`, always the header plus two cells; `carve_chunk()`
rounds it up to a buddy order. A block is the
reclaim unit, returned only when every cell is free, so fewer cells drain
sooner at the cost of more carves. `chunk_max` is the arena size / 64 within
`HG_CHUNK_MIN` (8 KB) and `HG_CHUNK_SMALL` (256 KB), so a small pkg arena is
not spent on one chunk per class. `HG_CHUNK_MAX_CELLS` (128) bounds a block
for its free map (an 8 KB block of 64-byte cells holds 126 on LP64).
`carve_chunk()` stamps every cell FRESH with its class before the block is
reachable, and gives the block to the carving thread as its bump range.

### 3.5 Large tier

`hg_large.c` serves what does not fit the largest cell with boundary-tag
fragments in chunks from the buddy: a block for a chunk up to a page (the slack
becomes free space), a run of pages above (a big hash table is one allocation).
On arenas of at least `HG_LARGE_BIG_ARENA` (256 MB) a chunk is at least one
page, header included, so the buddy returns a page, not a two-page run; smaller
arenas use `HG_LARGE_DEFAULT_CHUNK` (1 MB) capped at `chunk_max`.

A fragment is `struct hg_lfrag`, a cell header with class `HG_LARGE_MARKER`
(`HG_NCLASSES`), and the payload; sizes round to `HG_PAYLOAD_ALIGN` since a
size places the next fragment. Large allocations are rare and slow anyway,
so one unsorted first-fit free list per arena suffices. Remainders above a
header plus `HG_LARGE_MIN_FRAG` split off; frees coalesce both ways inside
the chunk up to a zero-size sentinel, and an empty chunk returns to the
buddy at once (`large_chunks_carved`/`_returned` show churn). The backing is
charged to `real_used` when taken; `large_live` tracks what is handed out.
`hg_large_free()` re-checks the state under the lock, since two frees can
both pass the unlocked check; a LIVE tag on a listed fragment is damage. On
exhaustion the tier grows and retries once, without a pressure flush.
Realloc always moves a large fragment.

## 4. Backing tiers and their verification

`enum hg_mem_tier`, best first: `HG_MEM_HUGETLB` (`MAP_HUGETLB`),
`HG_MEM_THP_ADVISE` (`MADV_HUGEPAGE`, huge at fault), `HG_MEM_THP_COLLAPSE`
(`MADV_COLLAPSE` after the fill), `HG_MEM_4K`. A tier is an outcome per
range: each page records its commit's tier (`hg_page.tier`), and
`tier_bytes[]` counts bytes per tier (`tier_bytes` in hg.stats).

**Reserve** (`hg_mem_reserve()`, Linux):

1. Tier 1 maps the cap with `MAP_HUGETLB`, else INIT alone as a fixed arena:
   huge pages beat THP with growth room. Never for small mode or a private
   (pkg) arena: a module may `fork()` a child the core does not initialise,
   which then holds the arena copy-on-write; a copy-on-write fault in
   hugetlb needs a fresh huge page, the child holds no reservation, and an
   empty pool means SIGBUS; THP splits to 4 KB instead.
2. Tiers 2-4 reserve `PROT_NONE` and map the whole cap read-write
   `MAP_FIXED` at an aligned address inside it (shmem THP needs address and
   file offset congruent modulo the huge page). The shm mapping exists before
   any fork, so it is the same in every process and a grow only faults in
   more of it; a range mapped after the fork would exist only in its mapper.
   An untouched tail costs page tables, not memory.
3. `MADV_HUGEPAGE` on the cap, then `mlock()` of INIT to populate and pin. A
   rise of `ShmemHugePages` (shared) or `AnonHugePages` (private) by 90% of
   the range means THP_ADVISE; else `MADV_COLLAPSE`, verified by a rise of
   the whole range; else 4 KB, with the host setting named when it is the
   cause. A small-mode arena skips this step and is 4 KB.

The counter delta replaces `/proc/self/smaps`, which walks the page tables of
the whole mapping; it is host-wide, hence 90%, and a false negative costs
only a collapse attempt. `MADV_COLLAPSE` bypasses the host's THP "never", so
hg honours "never" and shmem "deny" itself (`hg_thp_collapse_denied()`).

**Commit** (`hg_mem_commit()`, unlocked) uses `mlock()` on every tier of a
pinned arena: it
populates the exact range and fails with an errno, not a later SIGBUS in
whichever process touches a missing page. An unbacked commit fails whole,
while the buddy still treats the range as nonexistent. On hugetlb it is just
the populate (the pages are unswappable). On tiers 2-4 the delta is
re-advised, populated, pinned and verified. An arena whose INIT could not be
pinned is unpinned from the start (`hb->unpinned`), and so is one whose
commit `mlock()` fails while `RLIMIT_MEMLOCK` binds: from then on commits
populate by `MADV_POPULATE_WRITE` or writes, without `mlock()`. That memory
is swappable anyway and the pin a latency promise. A failure without a
binding limit refuses the grow.

**Deferred collapse.** `MADV_COLLAPSE` is slow and an exhausted worker waits
on its grow. So when a shared arena grows on exhaustion and the maintenance
process runs, a delta that did not come out huge is published on 4 KB pages
with `HG_COLLAPSE_TRIES` (16) attempts; `hg_collapse_deferred()` works them
off there, one pass per tick within `HG_COLLAPSE_BUDGET_NS` (100 ms), unlocked
around each `madvise`, retrying transient failures (pages just faulted
cannot be isolated yet). Other span grows collapse inline; a re-committed
hole only re-pins (5.7).

**Release** (`hg_mem_release()`): `munlock()`, then `MADV_REMOVE` when shared
(punching the shmem object for every process; hugetlb pages return to the
pool) or `MADV_DONTNEED` when private. A failure is structural and latches
`shrink_unsupported`. **Re-pin** (`hg_mem_repin()`): a punched page is
committed again by the process whose grow takes it, a worker that ran out or,
for shm, the maintenance process's headroom rule, as `mlock()` is per mapping
and not inherited across fork. On tiers 2-4 a failed re-pin still populates
and counts `repin_failed`, rather than turn a pinning shortfall into an
allocation failure under the pressure that caused it; on hugetlb it refuses,
the page being back in the pool and a touch a SIGBUS.

Off Linux the mapping is plain, on the 4 KB tier, pinned when `mlock()`
allows; release is refused and there are no cgroup checks. Arenas are kept
out of core dumps (`MADV_DONTDUMP`), being pre-faulted, unless the
environment sets `HG_DUMP_ARENA` (not `0`), read at arena creation.

## 5. Elastic arenas

### 5.1 Growth on exhaustion

With no buddy block for a carve, `carve_chunk()` first flushes the calling
thread's caches for that arena and returns drained blocks with no keep (the
pressure flush, `hg_cache_flush_locked()`), retrying if a block came back. Then
it grows (`HG_GROW_EXHAUSTION`), or waits for another process's grow, and
retries once; the retry can still miss when other processes took the new pages
first, and the carve then fails as after a refusal. A failure is logged in full
once per episode (`hg_oom_first()`) and summarised every 30 s (`hg_oom_take()`):
by the maintenance process for shm, the owner's sweep for a private arena.

### 5.2 Three-phase grow

`buddy_grow_body()`: (1) **reserve**, locked: re-commit holes first (5.7),
else size the delta (the granule, or the request in whole granules, capped
by the room below `hcap`) and claim the range (`grow_inflight`); (2)
**populate**, unlocked: first the host RAM check (`hg_grow_room_short()`,
which reads `/proc`; a refusal is recorded under the lock by
`hg_grow_room_refused()`), then `hg_mem_commit()`, whose faults, pin and
verification would otherwise stall every slow path; (3) **publish**, locked:
pages published whole, `size`
grown, `span_end` and `committed_bytes` stored last with release semantics,
so no lock-free reader sees the figure before the pages exist.

`grow_inflight` is one token for grow, trim, punch and hole re-commit. A
worker that runs out during a grow waits unlocked, polling every
`HG_GROW_WAIT_SLICE_US` (100 us) for up to `HG_GROW_WAIT_MAX_NS` (2 s). A
moved `grow_gen` means pages were published and the carve retries (a trim or
punch holding the token does not move it). The token can be retaken between
poll and relock, so the wait repeats within its budget; a token still held at
the limit refuses the request (`HG_GR_WAIT_TIMEOUT`).

### 5.3 Growth ahead of demand

The headroom rule (`hg_grow_headroom_tick()`, `hg_grow_ahead`): while
`span_end` is under the cap and no grow is in flight, keep free space above
twice the reserve floor by growing a granule. The maintenance process applies
it to an elastic shm arena every second, so no SIP worker waits on that
populate; a private arena applies it in its owner's sweep. Growth on
exhaustion stays armed.

### 5.4 Reserve floor

`reserve_floor` is 1/16 of the leaves of the committed pages, not of the
span (`floor_recompute()`), since a hole is address space without memory; a
fraction, because arena sizes differ widely. `hg_reserve_floor_check()` runs
on every grid allocation and free; a grow adds free space without it, so
recovery from a grow shows at the next one.
Falling below sets the `below_floor` latch, counts `floor_crossings` and
bumps `hg_sweep_gen`. It warns only when the arena cannot grow out (committed
up to the cap, or grow-blocked): an elastic arena crosses the floor as it
grows, and "raise -m/-M" would be wrong advice. A quiet crossing that gets
stuck earns the warning once. Recovery needs more than twice the floor, so
the latch cannot flap, and it ends a grow-blocked episode.

### 5.5 Refusals and the grow-blocked latch

`enum hg_grow_refusal` names what refused the last grow: the cap, a wait
timeout, the host or cgroup floor, `RLIMIT_MEMLOCK`, the hugetlb pool,
another `mlock()` failure, or a hole that could not be re-pinned. Refusals
are counted always (`grow_refused`) and most are logged once per episode; a
wait timeout is only counted, and a failed hole re-pin is logged once per
arena. A cap
refusal is the configured limit, not a fault: it never latches, and only an
arena that has grown says so (a fixed arena lives at room 0).

Resource refusals run a two-step latch (`grow_resource_refused()`): the first
arms it at `gc_passes + 1`; a refusal after the GC has since returned a
block latches `grow_blocked`, so a spike that reclaim absorbs never alerts. A
full arena with nothing to reclaim returns no block, so the sweep-interval tick
(`hg_grow_blocked_tick()`) latches an armed episode that has refused again by
its next run and disarms one that has not. A span grow or recovery past
twice the floor clears it (`hg_grow_unblock()`). `hg_shm_grow_blocked` and
`hg_pkg_grow_blocked` are the alertable gauges; the maintenance process
repeats the shm warning every `HG_GROW_REWARN_SWEEPS` intervals.

### 5.6 Shrink: quiet window and drain

`hg_shrink_tick()` runs once per GC and shrink cycle (`hg_scaling_cycle` in the
maintenance process for shm, each sweep for a private arena). A tick is quiet
when the arena is above `committed_min`, no grow is in flight, it is neither
below the floor nor grow-blocked, its top page is whole-free (not needed with
interior release, which exists for a pinned top page), and free space passes
the drain's own gate, a page above four floors; the trim then re-checks each
page against what it would leave. Anything else, and any grow, resets the
count.
After `HG_SHRINK_QUIET_TICKS` (4) quiet ticks the arena drains:
`hg_drain_tick()` releases one step per call, top trim then interior punch,
re-testing the gates (abundance: a page above four floors) until a step
releases nothing. The maintenance process calls it every second for shm; a
private arena gets one step per completed quiet window.

The trim (`buddy_shrink_body()`) takes whole-free pages from the top, up to
`shrink_step`, never below `committed_min` or under twice the floor free, or
the headroom rule would grow them back. Taking from the top retracts the span
without holes; taking only whole-free pages needs no coordination between
processes, because a cell cached by any thread still counts as live in its
block, so its page is never whole-free. It runs in three phases like the
grow: pages leave the free list under the lock, so nothing carves them
meanwhile, and are marked `releasing`; the syscalls run unlocked; the
bookkeeping, or the put-back on refusal, is done locked.

### 5.7 Interior punch and re-pin

One live cell in the top page blocks the trim for every free page below. The
punch (`buddy_punch_body()`, only with `hg_interior_release`) releases
whole-free pages anywhere in the span but the top page, lowest first, up to
`shrink_step` and at most `HG_PAGES_PER_EVENT` (128) a step, with the trim's
floors. A punched page keeps its descriptor, bitmap and leaf orders and
leaves the free list first, so nothing carves it while it goes; it leaves
`buddy_free_leaves` and `committed_bytes`, while `span_end` stays.

A grow re-commits holes before extending the span (`buddy_regrow_holes_body()`):
their address is already the arena's, so one costs a pin and no address space.
They are re-pinned by the process whose grow takes them, lowest first, a granule
or the request, whichever is more, as holes and room allow and at most
`HG_PAGES_PER_EVENT` a time. A hugetlb hole that cannot be re-pinned stays a
hole, and the request is refused if none came back. A trim over a punched page
drops the hole from the span without charging the committed floor.

### 5.8 Invariants

- `committed_bytes + punched_pages * hps == span_end`, checked after every
  grow, trim, punch and re-commit (`span_check()`, else `HG_C_INTERNAL`).
- `buddy_free_leaves` counts carvable leaves only; `nfree[top]` is the
  population of `wfree`; nothing bump-carves after `buddy_ready`.
- `hcap` never changes; ownership tests use it, so growth and shrink never
  change an ownership answer.

## 6. Per-thread caches, shared pool and block GC

### 6.1 Private caches

Each thread has `palloc_slots[HG_MAX_INSTANCES]` (8) in `__thread` storage,
one `struct hg_palloc` per arena it uses, with per class a LIFO free list,
its count, a bump range and a `touched` flag. Per thread, not per process,
because reactor threads allocate concurrently in one process; the lock-free
path is correct only because this state has one owner. `hg_last` caches the
last slot, so the lookup is a TLS load and a compare.

The bound is a byte budget, turned into cells per class at init
(`private_caps_init()`): `HG_PRIVATE_PCT` (25%) of the arena for all threads
together, divided by the consumers (`hg_io_consumers()`: the reactor pool size
with `tcp_main_threads=2`, else online CPUs, clamped to 4..64 by
`HG_PRIVATE_CONSUMERS_MIN`/`MAX`), split evenly over the classes, capped at
`HG_PRIVATE_CAP` (256) cells. A flat count would mean very different memory in
class 64 and class 65536. A class whose single cell exceeds a thread's share for
it gets `priv_max` 0: a free hands such a cell straight back to the pool
(refills and carves still pass through the thread's list); such allocations are
rare and large. `priv_donate`, half the cap (at least 1), is always covered by a
chain whose length matches its count. The pre-fork arenas can exist before the
config is parsed, so `hg_post_cfg()` re-derives their caps once the reactor pool
size is known.

### 6.2 Fast paths

**Allocate** (`hg_cell_alloc()`): class from `size2class`; pop the private
list (a head outside the arena drops the list) or bump the thread's chunk. On
a miss: lock, pop up to `HG_REFILL_BATCH` (32) cells from the pool, else
carve. A cell must read FRESH or FREE with an intact checksum and its class,
else it is counted and dropped; LIVE (LIVE_G with the guard) is stamped with
one 32-bit store, and the counters move in the process's own cache line (a
reactor thread's own, in a threaded process).

**Free** (`hg_cell_free()`): ownership is checked before the header is read,
as a foreign pointer may be unmapped. The header must check and read LIVE or
LIVE_G (a guard is checked here);
one compare-and-swap (CAS) of the header word makes it FREE, so of two
simultaneous frees one wins. The cell goes on the private list (or the
quarantine, section 10);
past `priv_max`, `priv_donate` cells move to the pool under the lock. A chain
shorter than its count is resynced and counted (`HG_C_NFREE_UNDERFLOW`),
never walked past its end. With no TLS slot a cell goes straight to the pool
(`hg_cell_free_global()`).

### 6.3 Shared pool by blocks, graded by fullness

Free cells are pooled per block. In one mixed list per class each refill
would skim many blocks, top them all up a little, and few would ever empty.
A block keeps its own free list and count (`free_head`, `in_gpool`) and sits
on one of `HG_GRADES` (8) fullness lists per class (`bucket[c][g]`, grade =
free cells x 8 / cells), on `drained[c]` when every cell is free, or on none
when none of its cells is pooled.
`hg_gpool_pop()` scans from grade 0, the fullest partial block, so a refill
draws from one block until it is used up while emptier blocks drain; with no
partial block it reuses a drained one before carving. A bit per cell
(`gfree`, kept only at the pool boundary) makes a double free exact when the
second copy arrives, and checks each link the pool follows; a bad link is
dropped and its cells leak, but no cell is handed out twice. Cached cells
count as live in their block, which can delay a reclaim but never hasten one.

### 6.4 Block GC

A drained block (`in_gpool == cells`) returns to the buddy, where a carve can
take it back at the same order with no split or merge. `gc_class_run()`
returns the oldest first (`drained_tail`, O(1)), removes it from the chunk
registry, `slab_capacity` and `real_used`, and hands it over last, as the
buddy reuses its first bytes. Each class of a private arena or an elastic
shm arena keeps a demand-sized reserve (`gc_keep[c]`): `hg_gc_cycle()` sets
it to the larger of the last cycle's carves and half the previous keep,
capped at `HG_GC_KEEP_MAX` (8) blocks and `arena >> HG_GC_KEEP_BUDGET_SHIFT`
(1/256) bytes. Blocks beyond it return
in `hg_gc_tick()` (`HG_GC_TICK_BUDGET` 32 a call, round-robin over classes;
each second from the maintenance process for an elastic shm arena, each
sweep for a private one), in `hg_gpool_push()` only once a class runs
`HG_GC_EMERGENCY` (32) past its keep, so requests normally never walk the
drained list, and in the sweep flush (down to keep) and pressure flush (no
keep). `gc_deferred` stops pushes from returning blocks while a flush walks a
chain; the flush returns them afterwards.

## 7. Fork semantics

- **Shared arena.** A child inherits the shm mapping (header and lock
  included) and a copy of the forking thread's caches: free lists and bump
  ranges holding cells the parent owns too. Keeping that copy would give one
  cell to two processes. So when hg creates a shared arena it registers
  `pthread_atfork()` handlers, which run for every `fork()`, also one that
  bypasses `fork_process()`. Before the fork, `hg_cache_fork_prepare()` hands
  the forking thread's shared-arena caches back to the pool: free lists,
  debug quarantine and bump remainder, nothing kept. In the child,
  `hg_malloc_child_init_all()` clears that thread's slot for each shared
  arena (`hg_kam_child_init()` runs it again, to no effect). The parent
  refills from the pool on its next allocations. `fork()` copies only the
  forking thread, and later threads get fresh TLS.
- **pkg.** The pre-fork arena stays mapped copy-on-write in every child; its
  state is self-consistent private memory and is not reset. The child then
  creates its own pkg arena (full tier ladder, `-M INIT:CAP`) and installs a
  fresh pkg API (`hg_kam_child_init()`, run by `fork_process()` and
  `fork_tcp_process()` before anything allocates). The main process keeps
  the pre-fork arena. The child's sweep still flushes the copied caches of
  its copy, and runs GC and the shrink tick on it, but never grows it,
  latches it grow-blocked or publishes it as the child's pkg arena: nothing
  allocates from it.
- **Cross-arena frees.** A child may free what its parent allocated before
  the fork (a module may release in `child_init()` what `mod_init()` built).
  A pointer outside the named arena is looked up in the registry
  (`hg_owner()`; `hg_arena_reg[]`, `HG_ARENA_REG_MAX` 8, process-local,
  `[hbase, hbase + hcap)`) and freed straight into its owner's pool, past the
  cache, as this process will not allocate there again; the shm arena counts
  these frees for every process (`xarena_frees`, hg.stats
  `cross_arena_frees`).
  Only a pointer of no arena is a defect (`HG_C_FOREIGN_PTR`).
- **Admission.** Before each fork `hg_kam_fork_fits()` checks that the
  child's pkg INIT fits in RAM above the floor; else the fork fails cleanly
  instead of the child being OOM-killed.
- `hg_hdr_secret` is set before the first arena, the same in every process.

## 8. The sweep and the maintenance process

### 8.1 The idle-cache sweep

Cached cells live in TLS, so only their thread can return them and no central
sweeper can. Each process sweeps itself in `hg_sweep_point()`
(`KSR_MEM_SWEEP_POINT()`), run inside `cfg_update()` in the main loops, on an
idle UDP receiver's timeout (`SO_RCVTIMEO` 1 s under hg; a signal that ends the
wait with EINTR counts the same) and in the TCP reader's timer. Its turn comes
every `HG_SWEEP_INTERVAL` (30) s, offset by a multiplicative hash of
`process_no` so processes do not queue on the lock together; the first call
starts the clock. The sweep is skipped when the process's shm cache slot is
clean and pkg is not hg, except every `HG_SWEEP_FORCE_EVERY` (4)th interval.
A free, a refill from the pool and, under hgdbg, a quarantine drained by an
allocation mark the slot dirty, as each leaves cells on a free list; a carve
does not, as the sweep never returns a bump range. The sweep marks the slot
clean before it walks the caches. With hg pkg the sweep raises
`SREV_PKG_UPDATE_STATS`. The TCP reactor threads are
reached through `hg_sweep_gen`, bumped by each sweep and floor crossing, which
they check at each job boundary (`hg_cache_flush_if_due()`). A plain counter
suffices: a missed generation only delays a flush.

`hg_cache_flush_self()` flushes every arena the thread caches in, locking per
class and per `HG_FLUSH_BATCH` (64) cells: the chain is TLS, only pushes and
GC need the lock, and dropping it between batches is safe because a block is
reclaimed only when all its cells are pooled. A class used since the last
sweep keeps `min(priv_max / 4, HG_FLUSH_KEEP)` (8) cells, since emptying an
active cache turns the next allocation into a locked refill; idle classes,
and all classes below the floor, give back everything. A last hold updates
the counters and, for a private arena, runs its GC cycle and tick, shrink
tick and live-peak sample; the grow-blocked tick, the headroom rule and the
published pkg growth state are for the arena `pkg_malloc()` serves only
(section 7).

Two more flushes give back everything, the bump remainder included:
`hg_cache_fork_prepare()`, for the shared arenas before every fork (section
7), and `hg_cache_drain_self()`, for every arena when a thread ends. The
latter runs from the destructor of a `pthread` key that a thread arms each
time it claims a cache slot, so a free made by a later destructor claims a
slot and arms the key again. A slot is marked clean by the process's own
sweep, or by a thread's sweep when the thread has a stats slot of its own;
a thread sharing its process's slot leaves the flag alone, or it would mark
clean what the main thread still holds.

### 8.2 The maintenance process

`hg_maint_start()` forks "hg maintenance" (`fork_process(PROC_NOCHLDINIT,
...)`, counted by `calc_proc_no()`) whenever hg serves shm. It wakes every
`HG_MAINT_SLEEP_US` (100 ms), calls `cfg_update()`, and ticks every
`HG_MAINT_TICK_MS` (1 s). For an elastic shm arena (cap above INIT) a tick
runs, locked, the headroom rule and `hg_gc_tick()`, every `hg_scaling_cycle`
ticks also `hg_gc_cycle()` and `hg_shrink_tick()`, else `hg_drain_tick()`;
then the deferred collapse, locking per page. `maint_active` in the shared
block tells workers it runs, so their exhaustion grows defer the collapse and
leave the headroom rule to it. Every second it samples the live peak, kept
even when nobody reads statistics; every `HG_SHARED_INTERVAL` (30) s it logs
the failed-allocation summary, runs the grow-blocked tick (and, when
`maint_active` is not set, the grow and shrink ticks), and logs the deferred
lock-stall and grow-blocked warnings with no arena lock held; the latch's
own first warning is logged under it. pkg arenas are
left to their process's sweep.

## 9. Locking rules and invariants

- `hb->lock` is a `gen_lock_t` in the arena's own mapping, alone on its cache
  line with the holder-only `lk_t0`/`lk_cur`. The read-mostly fields the fast
  path needs most (bounds, cache caps) precede it, written at init and, for
  the caps, once before the first fork, so lock traffic leaves them alone.
- **Locked**: pool push and pop, carving, all buddy work, the large tier, GC,
  flush batches, grow, shrink and punch bookkeeping, statistics walks.
  **Unlocked**: private lists, bump ranges, header stores and the free CAS,
  per-process counters, and the commit, release and re-pin syscalls.
- **`*_unlocks` contract.** `hg_buddy_grow_unlocks()`, the static trim, punch
  and hole re-commit helpers, and the ticks calling them
  (`hg_grow_headroom_tick()`, `hg_grow_tick()`, `hg_shrink_tick()`,
  `hg_drain_tick()`) are entered locked, drop the lock inside and return
  locked under the caller's section reason. Nothing read before the call is
  valid after it, so callers redo their buddy lookup. `hg_lock_assert_held()`
  checks both ends of the helpers and the grow, headroom and shrink ticks
  (`HG_C_INTERNAL` on a breach).
- Pages between list removal and bookkeeping are `releasing`; scans of
  bitmaps instead of lists skip them and punched pages.
- **Header states**: carve gives FRESH; allocation turns FRESH or FREE into
  LIVE, or LIVE_G with the guard; free turns LIVE or LIVE_G into FREE, by CAS
  for cells and under the lock for large fragments. Moving a cell between
  lists, pool and quarantine keeps its state, so a double free is refused
  whatever happened between. The values 0x3c, 0x5a, 0xa5, 0x96 differ from
  0x00, 0xff and each other.
- **Checksum**: 16 bits over address, class, state and the per-run secret,
  base(address, class) XOR key(state), one multiply. It catches a header
  overwritten by a neighbour's overflow, a pointer into a cell's middle, and a
  header copied elsewhere; it is not cryptographic.
- **A relaxed CAS suffices**: the CAS alone picks the winner, and the loser
  writes nothing; the winner's later writes go to its private list or
  quarantine, read only by its thread; a FREE cell reaches another thread only
  through `hg_gpool_push()` under `hb->lock`, whose release and acquire order
  header and link before the next `hg_gpool_pop()`.

## 10. Debug checks

`DBG_HG_MALLOC` is compile-time, set by `DBG_SR_MEMORY` (`MEMDBG=1`). It
adds the caller's file, function, line and module to each cell header and
enables per-site summaries; on a debug arena the free's site replaces the
allocation's, so a later write is reported against the free. `hgdbg` is a
run-time choice per memory type (`hb->dbg`):

- **Red zone.** Each allocation is `HG_DBG_TAIL` bytes larger. The payload's
  last word holds the requested size XORed with a per-address key, so neither
  red-zone bytes nor a small integer reads as a size; the gap holds
  `HG_DBG_REDZONE` (0xcc). Free and realloc check it (`HG_C_OVERFLOW`) and go
  on: the damage stayed in the cell, and a neighbour header it reached fails
  its own checksum. Large fragments carry it too.
- **Quarantine.** A freed small cell is filled with `HG_DBG_POISON` (0x6b)
  and parked in a per-thread, per-arena ring, mapped outside the arena on
  first use and bounded by `HG_QUAR_CELLS` (256) and `quar_bytes` (`cap >>
  10` within `HG_QUAR_MIN` 16 KB and `HG_QUAR_MAX` 1 MB). A cell leaving must
  be all poison under an intact FREE header, else it leaks and is counted
  (`HG_C_USE_AFTER_FREE`, `HG_C_HEADER`). An allocation that would fail
  drains the quarantine and retries.

Sanitizers (`hg_san.h`): an arena is one mapping, so ASan or Valgrind
memcheck (`-DHG_VALGRIND`) sees every byte as addressable. The hooks open the
requested bytes, close the rest, keep a free cell closed but for its link,
and reopen a block returned to the buddy. They cover private arenas only:
both tools track state per process, so a shared cell closed in one process
would raise false reports once another reuses it; shared memory relies on the
poison. ThreadSanitizer is told about `hb->lock`. Without a sanitizer the
hooks compile away. `-DHG_PARANOIA` re-walks drained lists to check tails.

Corruption counters (`enum hg_corrupt_kind`, `hb->corrupt[]`) count
detections: each site has refused the operation, leaked the cell or reset the
record it found wrong, and a few only report (`span_check()`,
`hg_lock_assert_held()`). Kinds are grouped by what an operator would do, so one
defect seen from several angles reads as one; hg.stats lists them under
`corruption_kinds`. Every site logs before it counts, and
with the core `mem_safety` at 0 the count aborts (`hg_corrupt_abort()`), so
the details are in the log first. Under `DBG_HG_MALLOC` a free of a pointer
of no arena aborts unless `mem_safety` is on.

**Tail guard (`mem_guard`).** A core parameter, default 1 when
`DBG_SR_MEMORY` is defined and 0 otherwise, changeable at runtime, read per
allocation (`hg_guard_on()`); a debug arena never guards, its red zone does
more. A guarded allocation is sized `HG_GUARD_ROOM` (1) byte up and stamped
LIVE_G, a state of its own under the checksum, so cells from before and after
a change coexist. The requested size, XORed with a key from the header's
base, goes in a header word otherwise unused (`req`: the second half of the
first `HG_ROUNDTO` bytes where that is 8, else the header's tail padding;
pinned by static asserts), and up to `HG_GUARD_LEN` (8) bytes of
`HG_GUARD_BYTE` (0xcc) follow the request, fewer where the cell ends sooner.
Free and realloc check it (`HG_C_OVERFLOW`; `hg_guard_bad()` names the first
changed byte) and go on; a realloc in place moves it to the new size. Large
fragments carry it for requests under 4 GB.

## 11. Statistics, counters and the hg.stats RPC

- **mem_info** (`hg_info()`, also behind `hg_kam_report()`): total is the
  arena size (grown by span grows, shrunk by trims); used is payload handed
  out; real_used is carved bytes less idle slab capacity, so it falls with
  load; free is room left to carve, not size minus live, since cached cells
  serve only their class; max_used is the peak of real_used. `xavailable`
  adds the room under the cap.
- **Fast-path counters** sit in `struct hg_pstat` slots of a cache line each
  (`HG_STAT_SLOTS` 1024), signed because one process frees what another
  allocated, summed and clamped on read. Process `n` uses slot `n + 1`;
  threads claim slots from the top down to one above the process count
  (`hg_thread_stats_init()`), sharing their process's slot when none are
  left. Above 1023 processes the process slots wrap onto each other and
  `hg_kam_prefork()` warns. `hg_slab_recycled()` reads a running sum, so
  statistics never walk chunks under the lock.
- **hgmem counters** (`hg_register_stats()`, read through callbacks): the
  shm arena's `hg_shm_*` (`hg_stat_defs[]`) cover sizes and peaks (total,
  pinned, carved, live, payload, cells, slab and large tiers), reclaim
  (blocks carved and returned, GC passes and who returned, flushes, skipped
  sweeps, buddy splits, merges and free leaves), the floor, corruption, the
  grow and shrink ledger
  (committed, cap, grows, refusals, blocked, shrinks, punches, re-pins and
  their bytes, hole re-grows, whole-free pages) and lock stalls. Each process
  publishes its pkg arena's committed bytes, grows, shrinks, refusals,
  blocked state and carve peak to a shm array (`hg_pkg_publish()`): the main
  process when the array is made, a child when it creates its arena, then
  each at its sweeps; summed as `hg_pkg_grow_refused` and
  `hg_pkg_grow_blocked`. The counters are 64-bit (`counter_val_t` is
  `long`), but the counters module's RPCs (`cnt.get`, `cnt.grp_get_all`)
  cast each value to `int`, so a byte counter above 2 GB, such as
  `hg_shm_committed` on a large arena, reads wrapped there; `hg.stats`
  carries 64-bit values.
- **hg.stats RPC**: a `shm` struct (tier and bytes per tier, committed, cap,
  committed_min, live and carved with peaks, grow ledger, the last grow
  refusal's reason, grow waits and their timeouts, deferred THP collapses,
  shrinks, punches, whole-free pages, corruption in total and by kind,
  cross-arena frees, lock stalls and longest hold, cache and pressure
  flushes) and a `pkg` struct of the published sums.
- **hg.advise RPC**: the `-m` and `-M` caps the peaks so far ask for. It
  works from each arena's carve peak (`max_real_used`), what had to fit,
  which can sit well above live: for shm the arena's own, for pkg the
  largest any process published (its own when none has). The recommended
  cap is the peak times a margin, 2 for shm and 3 for pkg (shm exhaustion
  fails an allocation, pkg exhaustion ends the process), at least a floor
  of 8 and 2 MB, in whole huge pages. The verdict is the peak as a share of
  the cap: above 70% "TIGHT", above 50% "watch", below 20% "oversized",
  else "reasonable". The pkg struct adds the process count and the totals
  over all of them; the notes say the peaks can only rise, that under two
  hours of uptime the numbers are provisional, and that the pkg peak is the
  worst process's as of its last sweep.

Example output of both, from an idle instance started with
`-m 64:256 -M 4:32` on 4 KB pages, after a 200 MB shm burst and a 20 MB pkg
burst in the ctl process.

`kamcmd hg.advise`, once the ctl process's sweep had published its peak:

```
{
    uptime_s: 39
    shm: {
        init_mb: 64
        cap_mb: 256
        peak_bytes: 234676224
        peak_pct_of_cap: 87
        margin: 2
        recommended_cap_mb: 448
        verdict: TIGHT - raise it before the next busy period
    }
    pkg: {
        init_mb: 4
        cap_mb: 32
        peak_bytes: 33423360
        peak_pct_of_cap: 99
        margin: 3
        recommended_cap_mb: 96
        verdict: TIGHT - raise it before the next busy period
        processes: 14
        cap_total_mb: 448
        recommended_total_mb: 1344
    }
    notes: {
        the advice is based on the peaks reached so far; a longer or busier period can only raise them
        uptime is under 2 hours, too short to have seen a busy period: treat the numbers as provisional
        the pkg peak is the worst single process's, as published at its last idle-cache sweep; -M has to cover it, and every process gets an arena of that size
    }
}
```

`kamcmd hg.stats`, after the shm burst was freed, the quiet window had passed
and the drain had run:

```
{
    shm: {
        tier: plain 4K pages
        committed: 234881024
        cap: 268435456
        committed_min: 67108864
        live: 2570128
        live_peak: 231618448
        carved: 5824512
        carved_peak: 234676224
        tier_bytes: {
            hugetlb: 0
            thp_advise: 0
            thp_collapse: 0
            4k: 234881024
        }
        grows: 12
        grows_proactive: 3
        grows_exhaustion: 9
        grow_refused: 0
        grow_blocked: 0
        shrinks: 1
        shrink_bytes: 33554432
        punches: 0
        punch_bytes: 0
        whole_free_pages: 108
        grow_refuse_reason: none
        grow_waits: 1
        grow_wait_timeouts: 0
        collapse_deferred: 0
        collapse_done: 0
        collapse_retries: 0
        collapse_failed: 0
        corruption: 0
        corruption_kinds: {
            class_mismatch: 0
            double_free: 0
            free_count_underflow: 0
            bad_class: 0
            foreign_pointer: 0
            bad_buddy_free: 0
            internal: 0
            damaged_header: 0
            use_after_free: 0
            overflow: 0
        }
        cross_arena_frees: 1
        lock_stalls: 0
        lock_hold_max_us: 99
        cache_flushes: 19
        pressure_flushes: 10
    }
    pkg: {
        processes: 14
        committed: 58720256
        committed_max: 4194304
        grows: 7
        shrinks: 1
        grow_refused: 1
        grow_blocked: 0
    }
}
```

The shm arena had reached its cap during the burst. The drain gave back the
32 MB of whole-free pages at its top and stopped at a page still in use; the
108 whole-free pages below it stay committed (section 16). The ctl process's
pkg arena, grown to its cap by the burst (`grow_refused: 1`), went back to
its 4 MB INIT in one shrink step once the burst was freed: `committed_max`
is 4 MB again and `committed` is 14 arenas of 4 MB.

- **Lock stalls**: each hold of `hb->lock` is timed. The longest is kept with
  its section (`enum hg_lock_reason`: refill, return, flush, large, policy,
  stats) and process; a hold of `hg_lock_stall_us` or more is a stall,
  counted and warned at most once a second per process and, for shm, by the
  maintenance process.
- **Dumps**: `hg_status()` logs at memlog level. With `DBG_HG_MALLOC`,
  `hg_sums()` and the module statistics count live cells and fragments by
  allocation site, listing them with the system `malloc()` while the walkers
  hold the lock. A cell counts as free if its block's map has it pooled, it
  is on the walking thread's private list (an open-addressed set sized from
  an exact count; an overflow is counted and reported), or its header is not
  LIVE.
  Before the fork the walk is exact; after it, other processes allocate and
  free unlocked while it runs.

## 12. Host memory checks

- **RAM floor** (`hg_ram_floor()`): `hg_ram_floor_mb` if set, else
  `hg_floor_mb_for(MemTotal)`, a twentieth of memory but at least the smaller
  of 256 MB and an eighth, so a small host is not asked for more than it has;
  256 MB if `MemTotal` is unreadable. Computed on each call.
- **Room**: `MemAvailable` above the floor, or the memory cgroup's room if
  tighter (`hg_memlimit.c`: own cgroup and every ancestor, the tightest
  limited level, usage less inactive file cache, a v1 memory line preferred
  to v2 `0::` on hybrid hosts), 64-bit on every build. Without `MemAvailable`
  the host check passes and `mlock()` decides. The hugetlb pool's room is
  free minus reserved pages.
- **When**: at arena creation (`hg_init_fits()`, which counts the pool for
  a shared arena only); before the first fork, `hg_capacity_check()` sums
  every child's pkg INIT against RAM (a private arena never uses the pool),
  refuses to start if they do not fit, and warns when the caps exceed the
  host's memory; before each fork (`hg_fork_fits()`); on each grow and hole
  re-commit (`hg_grow_room_short()`, read with the lock released, its
  refusal recorded under it by `hg_grow_room_refused()`; it passes hugetlb,
  whose pages left the pool at map time, and multiplies a pkg delta by the
  process count, as every process grows under the same load).
- **memlock**: `mlock()` checks `RLIMIT_MEMLOCK` for hugetlb too, so a low
  limit refuses grows with a full pool, with the same ENOMEM as an empty one.
  `hg_mlock_refusal_why()` tells them apart from `VmLck`, the pool counters
  and the limit (0 when unlimited or lifted by `CAP_IPC_LOCK`), and the
  warning names the cause. An elastic arena warns at startup when the limit
  cannot cover a granule (hugetlb: such grows fail) or the cap (other tiers,
  which then grow unpinned).

### 12.1 Host configuration examples

None of this is required: on a host with default settings hg runs on plain
4 KB pages, as the "4k" runs in why-hg-holds.md did. Each setting below adds
a tier or removes a limit. `kamcmd hg.stats` shows the tier each arena
reached (`tier`, `tier_bytes`), and at log level notice the startup line
names it with the reason when it is 4 KB. The figures below were measured
on the test host (16 GB, Debian 13, Linux 6.12) with `-m 128:4096 -M 4:32`
and 14 processes.

**Memory lock.** hg pins its arenas with `mlock()`. Under systemd:

```
# /etc/systemd/system/kamailio.service.d/hg.conf
[Service]
LimitMEMLOCK=infinity
```

then `systemctl daemon-reload`. Without it, on 4 KB and THP pages the arena
runs unpinned, so it can be swapped, and the log says so (`mlock of the
128 MB HG_MALLOC arena failed (...): continuing unpinned (swappable). If
running under systemd, add LimitMEMLOCK=infinity to the unit.`); on hugetlb
pages an elastic arena cannot grow past the limit, and hg warns at startup.

**Transparent huge pages** (tiers 2 and 3). `enabled` governs the private
(pkg) arenas, `shmem_enabled` the shm arena; the test host shipped
`enabled` always and `shmem_enabled` never, so with host defaults its shm
arena was on 4 KB pages. To allow both:

```
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo advise > /sys/kernel/mm/transparent_hugepage/shmem_enabled
```

`always` works too (`always` or `within_size` for shmem). To keep them
across reboots, `transparent_hugepage=madvise` on the kernel command line
sets `enabled`; `shmem_enabled` has no boot parameter, so:

```
# /etc/tmpfiles.d/kamailio-hg.conf
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/shmem_enabled - - - - advise
```

Tier 3 (`MADV_COLLAPSE`) needs Linux 6.1 or later. hg honours `never` and
shmem `deny` itself: it does not collapse, and the startup line says which
setting kept the arena on 4 KB.

**A hugetlb pool** (tier 1). hg maps the whole shm cap from the pool when
the arena is created; the pkg arenas never use the pool, since a module may
`fork()` a child that inherits one copy-on-write (section 4). For
`-m 128:4096` that is 2048 pages of 2 MB, so:

```
# /etc/sysctl.d/90-kamailio-hg.conf
vm.nr_hugepages = 2112
```

or `hugepages=2112` on the kernel command line, which allocates the pool
before memory fragments. The pool must exist before Kamailio starts, and
`vm.nr_overcommit_hugepages` lets it grow on demand. A pool that holds an
arena's INIT but not its cap gives a fixed arena on huge pages, logged
(`hugetlb pool cannot back a 4096 MB cap; reserving the 128 MB in use
instead - the arena keeps huge pages but cannot grow. Raise
vm.nr_hugepages to allow growth.`); a pool that holds neither leaves the
arena to the next tier. On the test host with a pool of 600 pages and
`-m 128:1024 -M 4:32`, the shm arena came up on `MAP_HUGETLB huge pages`
and every pkg arena on 4 KB pages; `HugePages_Rsvd` read 448, the 512 pages
of the cap less the 64 of its INIT, which were already faulted in.

**Overcommit.** On tiers 2 to 4 hg maps each arena's whole cap read-write
when the arena is created, so the caps count in `Committed_AS` at once:
with `-m 128:4096 -M 4:32` and 14 processes, `Committed_AS` rose by 4.9 GB
while 128 MB of shm and 4 MB per process were committed. A hugetlb pool
takes the shm cap out of that figure (it shows as `HugePages_Rsvd`
instead); the pkg caps stay in it. What this means per
`vm.overcommit_memory`:

- `0`, the default: in the kernel's words, obvious overcommits of address
  space are refused, so only a cap larger than the host's memory fails.
- `1`: nothing is refused.
- `2`: every mapping must fit under `CommitLimit`, swap plus
  `vm.overcommit_ratio` percent of RAM (or `vm.overcommit_kbytes`). On the
  test host, 50% of 16 GB with no swap, the caps above started; an 8192 MB
  shm cap did not, and Kamailio stopped with `failed to reserve the 8192 MB
  cap of the shm HG_MALLOC arena (128 MB to commit now): the host refused
  the mapping - with vm.overcommit_memory=2 the caps must fit under
  CommitLimit`. The choices are a higher ratio
  (`vm.overcommit_ratio = 80` in the file above gives 12.5 GB there), a
  hugetlb pool, or smaller caps.

To see where a host stands:

```
grep -E 'HugePages_(Total|Free|Rsvd)|Hugepagesize|CommitLimit|Committed_AS' /proc/meminfo
cat /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/shmem_enabled
sysctl vm.overcommit_memory vm.overcommit_ratio vm.nr_hugepages
```

## 13. File map

| file | holds |
|---|---|
| `hg_cell.h` | `HG_ROUNDTO`, classes, tiers, cell header, states, checksum, CAS, tail guard, `struct hg_lfrag`, `struct hg_chunk`, leaf geometry |
| `hg_block.h` | `struct hg_palloc`, `hg_pstat`, corruption kinds, lock stats, grow reasons and refusals, `struct hg_block`, address to page and leaf |
| `hg_malloc.h` | API: init, commit and host checks, OOM throttle, pkg publication, entry points, ownership, lock enter/leave, stats helpers |
| `hg_malloc.c` | arena creation and registry, fork handlers, header secret, `hg_post_cfg()`, `hg_info()`, `hg_status()`, per-site summaries |
| `hg_malloc_dyn.h` | `hg_malloc`, `hg_mallocxz`, `hg_mallocxn`, `hg_free`, `hg_realloc`, `hg_reallocxf`, `hg_resize` |
| `hg_backing.[ch]` | page probe, small mode, reserve, commit, release, re-pin, collapse, memlock causes, core-dump exclusion |
| `hg_hostmem.c` | RAM floor and room, hugetlb pool, init, capacity, fork and grow checks, pkg publication |
| `hg_memlimit.[ch]` | floor formula, cgroup room |
| `hg_buddy.[ch]`, `hg_buddy_int.h` | page descriptors, buddy, runs, grid self-test, list and bitmap helpers |
| `hg_elastic.c` | grow, hole re-commit, trim, punch, shrink and drain, headroom rule, grow-blocked latch, deferred collapse |
| `hg_pool.c` | fullness grading, pool push and pop, block GC |
| `hg_cache.c` | pressure, sweep, fork and thread-exit flushes, reserve floor, GC cycle and tick, sweep generation |
| `hg_arena.[ch]`, `hg_arena_int.h` | class table, TLS slots and their thread-exit key, chunk sizing and carving, cache caps, arena init, cell alloc and free, guard check, corruption abort |
| `hg_large.[ch]` | large tier |
| `hg_dbg.[ch]` | red zone, quarantine |
| `hg_stats.c` | recycled capacity, live-cell walk, thread stats slots, stall notes, hgmem counters |
| `hg_maint.c` | maintenance process (declared in `hg_hooks.h`) |
| `hg_kam.[ch]`, `hg_hooks.h` | memapi vtables, child init, tunables, sweep point, `hg.stats` and `hg.advise`, core hooks (`HG_ACTIVE()`, `KSR_MEM_SWEEP_POINT()`) |
| `hg_san.h`, `hg_version.h` | sanitizer hooks; the `HG_MALLOC` name |

Outside `mem/`: `main.c` (`INIT:CAP`, `hg_kam_post_cfg()`, `hg_kam_prefork()`,
`hg_maint_start()`, process count, `mlock_pages`), `pt.c` (fork admission, child
init), `shm.c` and `pkg.c` (manager names), `memcore.h` (manager init
prototypes), `cfg_struct.h` (sweep point in `cfg_update()`), `udp_server.c`,
`tcp_read.c`, `tcp_reactor.c` (sweep points, reactor hooks),
`tcp_reactor_mem.c`, `ver_defs.h`, `cfg_core.[ch]`, `cfg.lex`, `cfg.y` (the
`mem_guard` parameter), and the build files `src/Makefile.defs` and
`cmake/defs.cmake` (`HG_MALLOC`). The shm vtable's `xglock`/`xgunlock` do
nothing: hg locks internally, and a caller batching frees under
`shm_global_lock()` (tm's `free_cell()`) must not serialise on a lock hg does
not use. The shm "unsafe" variants are the locked functions.

## 14. Kamailio interfaces hg_malloc relies on

- **Frees under the global shm lock.** tm's `free_cell_helper()`
  (`modules/tm/h_table.c`) takes `shm_global_lock()` and frees the transaction
  with `shm_free_unsafe()`, letting go only around a tm callback's release
  function; so do the other `_unsafe` free helpers, such as tm's
  `sip_msg_free_unsafe()` (`sip_msg.h`) and `free_local_ack_unsafe()` (`uac.c`),
  and the core's `destroy_avp_list_unsafe()` (`usr_avp.c`), the xavp `_unsafe`
  destructors (`xavp.c`) and `dns_hash_put_shm_unsafe()` (`dns_cache.h`). Under
  hg `xglock`/`xgunlock` do nothing and the unsafe free is the normal free, so
  these callers need no change. hg's own arena lock must never be exposed
  through `xglock`: hg takes it inside the free path, so they would deadlock.
  The force-unlock in `cleanup()` (`main.c`) does nothing either.
- **`shm_address_in()`.** `reset_path_vector()` (`core/parser/msg_parser.c`) and
  `corex_lib.c` use it to decide whether `path_vec` may go to `pkg_free()`. The
  core pool's range test would be wrong for hg's own mapping, so under hg it
  asks `hg_shm_address_in()`.
- **`shm_available_safe()`.** The tls module compares it with
  `low_mem_threshold1` before completing a new connection and with
  `low_mem_threshold2` on established ones (`tls_server.c`). hg's `xavailable`
  reports what an allocation can still get: memory not yet cut into blocks, plus
  the room up to the cap.
- **`shm_mem_size`, `pkg_mem_size`.** They stay the INIT of `-m`/`-M`, so their
  readers work as before: corex (`corex_rpc_shm.c`), kex (`pkg_stats.c`), and
  xhttp_rpc, xhttp_pi and xhttp_prom, which size buffers as `pkg_mem_size / 3`.
  The caps are separate globals. `shm_force_alloc` touches the core pool only
  and does not apply under hg.
- **`pkg.stats`.** kex fills it from `SREV_PKG_UPDATE_STATS`, which hg raises at
  each process's sweep, not on every pkg call. A process that reaches its sweep
  point regularly lags by up to `HG_SWEEP_INTERVAL` (30 s); one that rarely does
  (the main process, an idle async worker) lags until it does.
- **Tests.** The core has no unit-test harness for the memory managers
  (`core/mem/memtest.c` is compiled out), and hg_malloc adds none. The misctest
  module's memory RPCs (`mt.mem_alloc`, `mt.mem_rnd_alloc`, `mt.mem_test_start`
  and the others) go through the selected manager, so they can drive hg as they
  are.

## 15. Open questions for review

Each of these is implemented one way; I would like a maintainer's view on
whether it is the right way for Kamailio.

1. **Compiled in by default?** `HG_MALLOC` is on in both builds, so packages
   carry hg; it is used only when selected by name.
2. **Detecting a thread-safe pkg manager.** `tcp_reactor_pkg_lock_install()`
   skips its mutex for hg by the manager's name, as it does for `sm`; a flag
   in `sr_pkg_api_t` would serve any future manager.
3. **Idle UDP receivers.** Under hg they get a 1 s `SO_RCVTIMEO` so that the
   sweep runs; the alternative is to accept that an idle receiver keeps its
   cache, bounded per thread, until its next message.
4. **`pkg.stats` lag.** Raising `SREV_PKG_UPDATE_STATS` on every pkg call,
   as fm and qm do, would add work to hg's lock-free path; raising it at the
   sweep lets `pkg.stats` lag by up to 30 s, longer for a process that
   rarely sweeps.
5. **Names.** Are `-x hg` / `hgdbg`, the `hg.stats` and `hg.advise` RPCs,
   the `hgmem` counter group and the `mem_guard` parameter acceptable names?

## 16. Limitations

Everything the sections above describe is implemented. This section lists
the limits of that implementation: each is a choice made on purpose, with
its reason and what an operator sees. None is unfinished work.

**Settings**

- The section 2 tunables are C globals with fixed defaults; neither the
  config nor the command line sets them. `hg_interior_release` is 0, so no
  interior page is ever punched: an arena shrinks from its top, and a live
  cell in the top page holds it at its current size.

**What is kept rather than returned** (bounded, never a leak)

- A thread's unused bump range, the end of its last block, is returned at
  thread exit and before a fork, not by the sweep: a block drains only once
  its carver has used or returned every cell. At most one block per class
  per thread.
- A process that ends does not return its cached cells. In Kamailio a
  child's end stops the server, so this does not arise at runtime.
- An idle async task worker blocks in `recvfrom()` with no timeout and
  sweeps only when a task arrives (`cfg_update()`): its cache waits until
  then.
- The main process waits in `pause()` and sweeps only after a signal, so its
  pkg arena stays at the size it reached during startup.

**When memory goes back**

- The maintenance process ticks only an elastic shm arena. A fixed one (no
  CAP) gets no GC tick or GC cycle from it, so its `gc_keep` stays 0 and
  drained blocks return to the buddy at flushes and when a class runs
  `HG_GC_EMERGENCY` (32) blocks past its keep.
- A floor crossing bumps `hg_sweep_gen`, which only the TCP reactor pool
  threads read, at their next job boundary. Every other thread, the crossing
  one included, flushes at its next sweep, or in a pressure flush when a
  carve finds no block.
- In a threaded process every reactor thread's flush also runs the private
  pkg arena's grow, GC and shrink ticks, once per thread per interval.
- A private arena releases one shrink step per completed quiet window.
- The shrink gate asks for a page above four floors free, so an arena of a
  few pages gives a page back only when about a quarter plus a page is free
  (an arena with an INIT of at least one huge page uses the huge page, 2 MB
  on x86_64, as its page whatever backs it).
- The headroom rule tests `span_end`, so once the span is at the cap,
  punched holes are re-committed only on exhaustion.

**Reporting**

- The `hgmem` byte counters are read wrapped at 2 GB through the counters
  module's RPCs, which print every counter as `int`; `hg.stats` is the
  64-bit reading (section 11).
- A free checks the header and the guard before its compare-and-swap, so
  two threads freeing the same cell at the same moment can both be in the
  checks before one of them claims it; both only read there, the CAS picks
  the winner and the loser is reported as a simultaneous double free. The
  one visible effect: for a request shorter than the 8 guard bytes the
  guard shares the first payload word with the winner's free-list link, so
  the loser may also log a spurious write past the size before its own
  claim fails.
- Two live figures: `hg_info()` subtracts only idle slab capacity from
  `real_used`; `hg_get_real_used()` (`hg_shm_live`, RPC `live`) also
  subtracts idle large-tier backing. Both feed `max_live_used`.
- A process forked other than by `fork_process()` or `fork_tcp_process()`
  gets the shared-arena reset of section 7 but not `hg_kam_child_init()`: it
  allocates pkg from its copy-on-write copy of the parent's pkg arena and
  keeps the parent's `process_no`, so its counters, and any pkg publication
  from its sweeps, go to the parent's slots.
- A grow-blocked arena and lock stalls are reported by log lines (from the
  maintenance process for shm) and counters; no event route runs.
