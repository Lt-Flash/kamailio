# hg_malloc's pkg path against the system allocator

`sm` is Kamailio's pkg manager backed by the libc allocator: `-X sm` routes
`pkg_malloc()` and `pkg_free()` to `malloc()` and `free()`, with no pool,
no statistics and no checks of its own. That makes it the floor for any pkg
manager's cost, and the reactor discussion on the pull request asked how
hg's pkg path compares with it. This page is that comparison, on the rig of
[why-hg-holds.md](why-hg-holds.md), with hg serving shm in every run so
that only the pkg manager changes.

## Contents

- [Setup](#setup) - builds, load, arms, what each column means
- [A. Memory debugging on, three passes](#a-memory-debugging-on-three-passes)
- [B. Memory debugging on, `mem_guard=0`, two passes](#b-memory-debugging-on-mem_guard0-two-passes)
- [C. Memory debugging off, two passes](#c-memory-debugging-off-two-passes)
- [D. Where the pkg time goes](#d-where-the-pkg-time-goes) - symbols, then
  the line level
- [E. sm serving pkg under the other shm managers, 60000 calls/s](#e-sm-serving-pkg-under-the-other-shm-managers-60000-callss)
- [F. Elastic arenas](#f-elastic-arenas) - the comparison again with
  `-m 128:4096 -M 2:32`, and how the arena grew
- [What it says](#what-it-says)

## Setup

- Build: the pull request's tree, cmake with the distribution's hardened
  flags, gcc 14.2, the DEFAULT module group; once with memory debugging on
  (`MEMDBG=ON`, Kamailio's default: every allocation records its file,
  function, line and module, `mem_guard` defaults to 1) and once with it
  off (`-DMEMDBG=OFF`, no site records, `mem_guard` defaults to 0),
  otherwise identical.
- Load: tm mode over UDP, an INVITE that tm answers with 486 and the ACK, 8
  workers, three sipp hosts, 85 s per point, 30000, 45000 and 60000 calls/s;
  `-m 4096` for shm, `-M 32` for an hg pkg arena. Passes alternate the arm
  order.
- Arms: `-x hg -X hg` ("hg"), `-x hg -X sm` ("hg+sm"), and hg with
  `mem_guard=0` in the config ("hg, guard off").
- Columns: *cores* is the CPU of every Kamailio process, user plus system,
  over a 20 s window in the middle of the load, divided by the window;
  *allocator share* is the share of Kamailio's CPU samples (perf cpu-clock,
  999 Hz, 15 s) in the manager's own functions (`hg_*`; for the shm
  managers of section E also `qm_*` and `tlsf_*`), so glibc's `malloc` and
  `free` are not in it: section D counts them; *probe p50 / p99* is the
  INVITE round trip of a separate low-rate sender through the loaded
  server; *failed* and *retransmissions* are sipp's totals over every UAC.

## A. Memory debugging on, three passes

| arm | calls/s | pass | cores | allocator share | probe p50 / p99, us | calls ok | failed | retransmissions |
|---|---|---|---|---|---|---|---|---|
| hg | 60000 | 1 | 4.21 | 7.0% | 360 / 1056 | 5100000 | 0 | 147 |
| hg | 60000 | 2 | 3.98 | 7.1% | 307 / 1173 | 5100000 | 0 | 826 |
| hg | 60000 | 3 | 4.08 | 6.8% | 309 / 1133 | 5100000 | 0 | 239 |
| hg+sm | 60000 | 1 | 3.93 | 2.5% | 326 / 1148 | 5100000 | 0 | 167 |
| hg+sm | 60000 | 2 | 3.93 | 2.8% | 304 / 790 | 5100000 | 0 | 201 |
| hg+sm | 60000 | 3 | 3.92 | 2.5% | 326 / 889 | 5100000 | 0 | 508 |
| hg | 45000 | 1 | 3.05 | 6.8% | 326 / 737 | 3823980 | 0 | 105 |
| hg | 45000 | 2 | 3.13 | 6.8% | 324 / 777 | 3823980 | 0 | 0 |
| hg | 45000 | 3 | 2.99 | 6.8% | 299 / 1034 | 3823980 | 0 | 10 |
| hg+sm | 45000 | 1 | 3.06 | 2.5% | 327 / 979 | 3823980 | 0 | 20 |
| hg+sm | 45000 | 2 | 3.08 | 2.5% | 400 / 894 | 3823980 | 0 | 0 |
| hg+sm | 45000 | 3 | 3.01 | 2.7% | 279 / 650 | 3823980 | 0 | 0 |
| hg | 30000 | 1 | 2.29 | 6.9% | 360 / 677 | 2550000 | 0 | 0 |
| hg | 30000 | 2 | 2.26 | 6.9% | 338 / 673 | 2550000 | 0 | 0 |
| hg | 30000 | 3 | 2.18 | 6.8% | 311 / 688 | 2550000 | 0 | 0 |
| hg+sm | 30000 | 1 | 2.20 | 2.5% | 318 / 762 | 2550000 | 0 | 0 |
| hg+sm | 30000 | 2 | 2.22 | 2.8% | 336 / 645 | 2550000 | 0 | 0 |
| hg+sm | 30000 | 3 | 2.12 | 2.7% | 351 / 707 | 2550000 | 0 | 0 |

Means: 60000 calls/s hg 4.09 cores, hg+sm 3.93 (-3.9%); 45000 hg 3.06,
hg+sm 3.05 (-0.3%); 30000 hg 2.24, hg+sm 2.18 (-2.7%). The allocator share
is 6.8-7.1% with hg serving pkg and 2.5-2.8% with sm, where it is hg's shm
side alone. The probe's p99 differs by less than the pass-to-pass spread
except at 60000, where hg+sm's is lower.

## B. Memory debugging on, `mem_guard=0`, two passes

| arm | calls/s | pass | cores | allocator share | probe p50 / p99, us | calls ok | failed | retransmissions |
|---|---|---|---|---|---|---|---|---|
| hg, guard off | 60000 | 1 | 3.94 | 6.7% | 352 / 1113 | 5100000 | 0 | 529 |
| hg, guard off | 60000 | 2 | 3.93 | 6.4% | 388 / 1116 | 5100000 | 0 | 168 |
| hg, guard off | 45000 | 1 | 3.09 | 6.7% | 299 / 620 | 3823980 | 0 | 0 |
| hg, guard off | 45000 | 2 | 3.08 | 6.5% | 300 / 664 | 3823980 | 0 | 0 |
| hg, guard off | 30000 | 1 | 2.19 | 6.8% | 311 / 602 | 2550000 | 0 | 0 |
| hg, guard off | 30000 | 2 | 2.17 | 6.2% | 323 / 653 | 2550000 | 0 | 0 |

The tail guard is 0.3-0.4 points of the allocator share and nothing in
cores beyond the spread of section A, as the guard runs of why-hg-holds.md
had found.

## C. Memory debugging off, two passes

| arm | calls/s | pass | cores | allocator share | probe p50 / p99, us | calls ok | failed | retransmissions |
|---|---|---|---|---|---|---|---|---|
| hg | 60000 | 1 | 3.79 | 5.7% | 279 / 719 | 5100000 | 0 | 50 |
| hg | 60000 | 2 | 3.77 | 5.7% | 324 / 948 | 5100000 | 0 | 34 |
| hg+sm | 60000 | 1 | 3.76 | 2.3% | 300 / 833 | 5100000 | 0 | 206 |
| hg+sm | 60000 | 2 | 3.88 | 2.4% | 300 / 868 | 5100000 | 0 | 3376 |
| hg | 45000 | 1 | 3.09 | 5.7% | 286 / 542 | 3823980 | 0 | 0 |
| hg | 45000 | 2 | 2.98 | 5.6% | 308 / 712 | 3823980 | 0 | 705 |
| hg+sm | 45000 | 1 | 2.96 | 2.4% | 297 / 555 | 3823980 | 0 | 0 |
| hg+sm | 45000 | 2 | 3.18 | 2.2% | 298 / 606 | 3823980 | 0 | 22 |
| hg | 30000 | 1 | 2.14 | 5.5% | 314 / 636 | 2550000 | 0 | 0 |
| hg | 30000 | 2 | 2.14 | 5.5% | 329 / 583 | 2550000 | 0 | 0 |
| hg+sm | 30000 | 1 | 2.13 | 2.1% | 318 / 672 | 2550000 | 0 | 0 |
| hg+sm | 30000 | 2 | 2.22 | 2.5% | 314 / 685 | 2550000 | 0 | 0 |

Means: 60000 calls/s hg 3.78 cores, hg+sm 3.82; 45000 hg 3.04, hg+sm 3.07;
30000 hg 2.14, hg+sm 2.17: equal within the spread, hg lower at every rate,
although hg's own functions still take 5.5-5.7% of the samples against
2.1-2.5% for its shm side alone. The debugging build's extra 1.3-1.4 points
are the four site-record stores per allocation and the guard; the rest of
hg's pkg time is paid back elsewhere, as section D shows.

## D. Where the pkg time goes

Symbols at 60000 calls/s, summed over the passes of sections A and C, as a
share of all Kamailio samples. The hg+sm arm's `hg_*` time is its shm side;
its pkg side is glibc's.

| build | arm | `hg_*` functions | glibc `malloc`, `_int_malloc`, `cfree`, `malloc_consolidate` |
|---|---|---|---|
| debugging on | hg | 3.15% | 0.00% |
| debugging on | hg+sm | 1.22% | 0.99% |
| debugging off | hg | 2.21% | 0.02% |
| debugging off | hg+sm | 0.88% | 0.95% |

So hg's pkg side is 1.93 points against glibc's 0.99 with debugging on and
1.33 against 0.95 with it off; the shm side (`hg_gpool_pop` 0.26-0.32% in
both arms) is the same in both. By function, debugging on then off:
`hg_cell_alloc` +0.63 / +0.50, `hg_cell_free` +0.46 / +0.44, `free_check`
+0.21 / +0.14, `hg_free` +0.21 / +0.07, `hg_malloc` +0.17 / +0.01,
`cell_push_private` +0.10 / +0.08, `private_head_ok` +0.09 / +0.06,
`hg_palloc_lookup` +0.04 / +0.03.

Line level, debugging off: one point at 60000 calls/s sampled for 20 s at
2999 Hz over every Kamailio process, `perf script` offsets joined with
`objdump -dl` of the binary. The share is of the samples in the eight pkg-
path functions; the line is where the function's samples concentrate, with
the sample landing on the instruction after a stalled load.

| function | share | hottest line | what it is |
|---|---|---|---|
| `hg_cell_alloc` | 38.0% | 24.7% after `cell_next(cell_start)` | the cache miss on the cell being handed out, reading its next pointer; glibc's tcache pays the same |
| `hg_cell_free` | 24.1% | 37.2% on the branch after `lock cmpxchg` | the LIVE to FREE claim of the header, one compare-and-swap (CAS): the atomic instruction that writes FREE only if the word still reads LIVE, so of two simultaneous frees one wins and the other is reported |
| `free_check` | 10.5% | 42.8% after the header-word read | the miss on the freed cell's first line; the checksum arithmetic is about a tenth of the function |
| `cell_push_private` | 6.7% | 14.6% in `cell_next` | the donate-half walk, which reads N/2 cells' next pointers when a class list crosses its bound |
| `hg_free` | 4.2% | the prologue and `%fs:0x28` | call overhead and the stack-protector canary (`-fstack-protector-strong`; `free_check()` takes `&hw` and `&hbase`) |
| `private_head_ok` | 3.9% | prologue and epilogue | an out-of-line call for a two-compare range test |
| `hg_backed()` inside `hg_cell_free` | 8.4% of the function | `hb->pages[]` | the page-descriptor lookup that keeps a free off a released page: a second cache line per free |
| the `hg_pstat` counters | 3.2% of alloc, 4.4% of free | `ps->fragments++`, `ps->used -=` | six read-modify-writes per alloc and free pair |
| `hg_guard_on()` | 2.5% of alloc | `cfg_get(core, core_cfg, mem_guard)` | the config read on every allocation |

Two thirds of hg's pkg cost is memory latency on the cells themselves and
one atomic; the rest is call structure, one extra cache line per free and
the counters. None of the checks' arithmetic is significant. Four trims
that keep every check follow from this (inlining the hot halves of the
free path with the error paths out of line; the page lookup only when a
page is punched or releasing; a plain store instead of the CAS on arenas no
second thread frees into; `mem_guard` read once per sweep); they are not
part of this change.

## E. sm serving pkg under the other shm managers, 60000 calls/s

The same load with `-x qm -X sm` and `-x tlsf -X sm` (`-m 4096`), two passes
on each build, hg+sm in the same passes as the reference. The last column
is the filed three-pass figure of why-hg-holds.md for the same shm manager
with its own pkg, per pass of 5100000 calls.

| build | shm | pass | cores | allocator share | probe p50 / p99, us | calls ok | failed | retransmissions | with its own pkg |
|---|---|---|---|---|---|---|---|---|---|
| debugging on | hg | 1 | 3.96 | 2.5% | 285 / 907 | 5100000 | 0 | 27 | 0 lost, 0 retransmissions, 4.02 cores |
| debugging on | hg | 2 | 3.91 | 2.7% | 300 / 653 | 5100000 | 0 | 6 | |
| debugging on | q_malloc | 1 | 5.35 | 64.0% | 152419 / 152419 | 3354970 | 1745030 | 15012484 | 37% lost, 14.9 M retransmissions, 5.34 cores |
| debugging on | q_malloc | 2 | 3.24 | 10.8% | 235210 / 544981 | 3193392 | 1906608 | 16340035 | |
| debugging on | tlsf | 1 | 4.42 | 2.2% | 342 / 1129 | 5099981 | 19 | 579142 | 0 lost, 0.38 M to 0.99 M retransmissions, 4.49 cores |
| debugging on | tlsf | 2 | 4.32 | 2.4% | 328 / 1207 | 5099962 | 38 | 676550 | |
| debugging off | hg | 1 | 3.75 | 2.4% | 312 / 854 | 5100000 | 0 | 18 | |
| debugging off | hg | 2 | 3.85 | 2.3% | 306 / 826 | 5100000 | 0 | 17 | |
| debugging off | q_malloc | 1 | 3.77 | 41.9% | 402 / 141538 | 3672887 | 1427113 | 14653496 | |
| debugging off | q_malloc | 2 | 3.49 | 16.9% | 177428 / 381687 | 3700327 | 1399673 | 14743939 | |
| debugging off | tlsf | 1 | 4.10 | 1.8% | 285 / 911 | 5100000 | 0 | 363708 | |
| debugging off | tlsf | 2 | 4.16 | 1.7% | 283 / 951 | 5099935 | 65 | 579538 | |

The pkg manager does not change which shm manager holds 60000 calls/s:
with glibc serving pkg, q_malloc loses more than a third of its calls with
its boundary checks on and more than a quarter with them off, tlsf
completes its calls at
the retransmission band it has with its own pkg, and hg is at zero loss
and the lowest CPU in both builds. shm is where the call rate is decided;
pkg is second order.

## F. Elastic arenas

Sections A to E ran fixed arenas (`-m 4096`, `-M 32`). The comparison of
section A again with elastic ones: hg shm `-m 128:4096` in both arms, hg pkg
`-M 2:32` against sm; memory debugging on; two passes with the arm order
swapped. Every point starts from the 128 MB INIT under the full rate, so
each one also measures the growth itself: `hg.stats` was read every 2 s
(committed bytes, the grow ledger, grow waits) from the middle of the first
pass on.

| arm | calls/s | pass | cores | allocator share | probe p50 / p99, us | calls ok | failed | retransmissions |
|---|---|---|---|---|---|---|---|---|
| hg | 60000 | 1 | 4.03 | 7.2% | 309 / 1002 | 5100000 | 0 | 15 |
| hg | 60000 | 2 | 4.00 | 7.5% | 313 / 968 | 5100000 | 0 | 2406 |
| hg+sm | 60000 | 1 | 3.88 | 2.5% | 304 / 773 | 5100000 | 0 | 488 |
| hg+sm | 60000 | 2 | 3.87 | 2.5% | 294 / 792 | 5100000 | 0 | 33 |
| hg | 45000 | 1 | 3.18 | 7.1% | 279 / 554 | 3823980 | 0 | 0 |
| hg | 45000 | 2 | 3.22 | 7.1% | 323 / 686 | 3823980 | 0 | 0 |
| hg+sm | 45000 | 1 | 3.12 | 2.5% | 296 / 614 | 3823980 | 0 | 0 |
| hg+sm | 45000 | 2 | 3.10 | 2.6% | 282 / 613 | 3823980 | 0 | 11 |
| hg | 30000 | 1 | 2.28 | 7.2% | 336 / 692 | 2550000 | 0 | 0 |
| hg | 30000 | 2 | 2.29 | 6.9% | 337 / 694 | 2550000 | 0 | 0 |
| hg+sm | 30000 | 1 | 2.27 | 2.5% | 299 / 695 | 2550000 | 0 | 0 |
| hg+sm | 30000 | 2 | 2.29 | 2.4% | 309 / 660 | 2550000 | 0 | 0 |

Means: 60000 calls/s hg 4.02 cores, hg+sm 3.88; 45000 hg 3.20, hg+sm 3.11;
30000 hg 2.29, hg+sm 2.28: the same figures as the fixed arenas of section
A within their spread (4.09 / 3.93, 3.06 / 3.05, 2.24 / 2.18), the same
allocator shares, no failed call, and retransmissions inside section A's
band.

How the shm arena grew, hg arm, second pass (the hg+sm arm's shm arena,
also hg, grew the same way to the same size within one step): committed MB
by seconds since the process came up, the load starting in the first
seconds.

| calls/s | 0 s, MB | 4 s, MB | 6 s, MB | 8 s, MB | 10 s, MB | 15 s, MB | 20 s, MB | 30 s, MB | plateau, MB | grows, count: on exhaustion / ahead of demand | grow waits, count | wait timeouts | shrinks |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 60000 | 128 | 576 | 1632 | 2400 | 2432 | 2528 | 2560 | 2560 | 2576 | 138 / 15 | 902 | 0 | 0 |
| 45000 | 128 | 832 | 1520 | 1728 | 1760 | 1856 | 1920 | 1936 | 1936 | 95 / 18 | 607 | 0 | 0 |
| 30000 | 128 | 464 | 992 | 1152 | 1184 | 1280 | 1296 | 1296 | 1296 | 61 / 12 | 387 | 0 | 0 |

The arena grows in 16 MB steps (the default granule, an eighth of the cap
capped at 16 MB): half of its plateau is committed 6 s in, nine tenths by
8 to 10 s, the last steps, ahead of demand, between 20 and 45 s, and it
stays there for the rest of the point - no shrink within 85 s, since the
quiet window is four 30 s cycles and the load never goes quiet. The plateau
is what tm holds at the rate: 2576 MB at 60000 calls/s (153 grows), 1936 at
45000 (113), 1296 at 30000 (73). More than four fifths of the grows are on
exhaustion, a worker having found the arena full. A grow wait is a worker
that found the arena full while another process's grow was in flight and
waited for its pages instead of growing itself; in that first ten seconds
workers
waited for a grow in flight 387 to 902 times, each wait within its 2 s
budget (no timeout, no refusal). That start-up cost no call at any rate,
and the cores and retransmissions of the whole point are those of an arena
that had the memory from the beginning.

**After the load.** The same arena after 60 s at 60000 calls/s with the
load then stopped and the server left up, `hg.stats` read every 5 s: tm
released its transactions within seconds of the last call, the arena stayed
at its size through the quiet window (four 30 s cycles with nothing to do)
and then drained in 64 MB steps, one a second, back to its 128 MB INIT in
about 40 s, and stayed there for the remaining four minutes. t is seconds
since the process came up; the load ran from 4 s to about 64 s.

| t, s | committed, MB | live, MB | whole-free pages | shrinks | shrink bytes, MB |
|---|---|---|---|---|---|
| 0 | 128 | 2 | 60 | 0 | 0 |
| 25 | 2560 | 2183 | 160 | 0 | 0 |
| 68 | 2560 | 2 | 1193 | 0 | 0 |
| 176 | 2560 | 2 | 1275 | 0 | 0 |
| 197 | 1344 | 2 | 668 | 19 | 1216 |
| 219 | 128 | 2 | 60 | 38 | 2432 |
| 453 | 128 | 2 | 60 | 38 | 2432 |

## What it says

- With memory debugging on, hg's pkg path costs about 4 points of
  Kamailio's CPU more than glibc, 0-4% in cores by rate: the price of the
  header state and checksum, the site records and the tail guard, which sm
  does not pay for anything. The guard is 0.3-0.4 of those points.
- With memory debugging off, hg and sm are even in cores, hg a touch lower,
  although hg's own functions still take about twice glibc's share: the
  difference is memory latency on the cells and one CAS per free, paid back
  by what glibc does elsewhere.
- Under any shm manager, sm changes the server's capacity by nothing that
  the shm manager does not decide.
- Elastic arenas give the same figures as fixed ones: an arena started at
  128 MB under 60000 calls/s reaches its 2576 MB plateau in about ten
  seconds, in 16 MB steps, with no call lost to the growth, and is back at
  128 MB about three minutes after the load stops.
