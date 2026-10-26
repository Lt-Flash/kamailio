# Why hg_malloc holds 60k calls/s in tm mode

This page explains what keeps hg_malloc running at call rates where q_malloc
and f_malloc collapse, using the CPU profiles taken at every test point. The
mechanism is in the code. The profiles are from three test passes on 4 KB
pages, each range covering all three; the later sections add the runs with
the tail guard, the builds without memory debugging, and the highest rate hg
held. The TCP reactor, where one process's threads share its pkg memory, is
tested in [tcp-reactor.md](tcp-reactor.md); hg's pkg path against the
system allocator, and sm under the other shm managers, in
[pkg-path.md](pkg-path.md).

## The pressure point: tm frees under the global shm lock

Every call in this test (an INVITE that tm answers with 486, then the ACK)
clones the request into shm and builds a tm transaction there
(`sip_msg_shm_clone()`, `build_cell()`). tm frees the transaction later, from
its timer process, in `free_cell_helper()` (`modules/tm/h_table.c`): it takes
`shm_global_lock()` and frees the pieces of the cell with `shm_free_unsafe()`
while holding it, letting go only around the release function of a tm
callback (this test registers none).

With q_malloc, f_malloc and tlsf, `shm_global_lock()` is the allocator's one
lock. While the timer process holds it to free, no SIP worker can allocate
shm, and at high rates the timer's frees and the workers' allocations queue
on that one lock.

## What hg_malloc does instead

- **No global lock to hold.** Under hg, `shm_global_lock()` and
  `shm_global_unlock()` do nothing (`hg_kam_glock()`): the allocator locks
  internally, so tm's batched frees do not stop anyone else.
- **Frees go to a private cache.** A free marks the cell FREE with one
  compare-and-swap on its header and pushes it onto the freeing thread's own
  cache, without a lock. Only when that cache passes its bound does half of
  it go to the shared pool, in one locked batch.
- **Allocations come from the worker's own cache.** On a miss, a worker
  refills up to 32 cells (`HG_REFILL_BATCH`) in one hold of the arena lock.

The shared pool's lock is taken once per batch, not once per allocation or
free, so the timer process's frees and the workers' allocations no longer
queue behind one another.

## What the profiles show

Test setup: Kamailio master (e41867c) with hg_malloc, built with
cmake and the distribution's hardened flags, with Kamailio's default memory
debugging on for every allocator (`MEMDBG=1`: q_malloc, f_malloc, tlsf and
hg_malloc all record the caller's file and line on each allocation, and
q_malloc also writes and checks boundary patterns); tm mode over UDP, 8 workers,
`-m 4096 -M 32`, 4 KB pages (transparent huge pages off, no hugetlb pool); a
16 vCPU virtual machine loaded by three sipp hosts; 85 s at each rate, every
rate run three times in a varying order. "Futex calls" are counted with perf
over a 10 s window of each point; "samples" are CPU samples of all Kamailio
processes with call graphs. Two binaries were tested: the hg build, Kamailio
master (e41867c) with hg_malloc, in which `-x fm` and `-x qm` select
f_malloc and q_malloc with hg compiled in but not used; and the "stock
build", the same master built the same way without hg_malloc. The "fm" and
"q_malloc" figures come from the first, the "fm, stock build" figures and
the stock q_malloc ones below from the second: a control for the hooks hg
adds to the core, which must do nothing when another manager is selected.

### At 45k calls/s, where hg, tlsf and f_malloc all hold

| | hg | tlsf | fm | fm, stock build |
|---|---|---|---|---|
| failed calls | 0, 0, 0 | 0, 0, 0 | 0, 0, 0 | 0, 0, 0 |
| CPU (cores) | 3.12-3.18 | 3.35-3.43 | 3.38-3.42 | 3.35-3.42 |
| futex calls per SIP call | 0.94-1.01 | 3.28-3.45 | 2.98-3.19 | 3.04-3.28 |
| share of futex calls on the allocator's lock | 2.6-3.3% | 83.0-83.9% | 77.5-77.9% | 75.5-77.7% |
| samples under shm allocation, its lock and the kernel | 1.7-2.0% | 15.3-16.6% | 11.9-13.0% | 11.2-14.6% |

With hg, 96.7-97.4% of the remaining futex calls come from tm's own timer
lists (`timer_add_safe_ctx()`, `timer_del_safe_ctx()`, `timer_list_expire()`),
not from the allocator.

### At 60k calls/s

| | hg | tlsf | fm | fm, stock build |
|---|---|---|---|---|
| failed calls (of 5.1M) | 0, 0, 0 | 76, 1119, 0 | 3.99M, 3.11M, 4.22M | 3.76M, 4.09M, 2.70M |
| CPU (cores) | 3.94-4.13 | 4.45-4.55 | 1.13-1.19 | 1.13-1.20 |
| futex calls per SIP call | 1.08-1.18 | 3.87-4.03 | - | - |
| share of futex calls on the allocator's lock | 2.4-3.1% | 82.6-83.1% | - | - |
| samples under shm allocation, its lock and the kernel | 1.5-1.8% | 16.2-18.8% | - | - |
| top function | `iowrite16` 6.8-6.9% | `iowrite16` 5.9% | `fm_free` 86.7-89.9% | `fm_free` 88.5-92.1% |

f_malloc collapses at 60k in all three passes of both builds. Kamailio's CPU
falls to about one core, and `fm_free()` alone takes 87-92% of the samples:
the frees run under the single lock while the other processes wait. The other
counters of a collapsed point depend on which phase of the collapse the
sampling window caught, so they are left out. q_malloc fails already at 45k
(15-19% of calls in every pass, both builds) and is not tabled; without
memory debugging it lost no call at 45k in the build with hg_malloc (see
below).

tlsf survives 60k because its allocation and free take constant time, so each
hold of the one lock is short. It still serialises every shm allocation: its
futex calls per SIP call rise from 3.28-3.45 at 45k to 3.87-4.03 at 60k, and
it lost calls in two of the three passes.

## With the tail guard

The same setup and three passes, built the same way (memory debugging on),
and the same config plus the `cfg_rpc` module,
used to read `mem_guard` back from every running instance. hg ran with its
tail guard at this build's default (`mem_guard` 1) and, as a fourth arm,
with `mem_guard=0`; q_malloc and tlsf ran in the same passes. The order of
the arms changed from rate to rate and from pass to pass.

| | hg | hg, `mem_guard=0` | tlsf | q_malloc |
|---|---|---|---|---|
| 60k: failed calls (of 5.1M) | 0, 0, 0 | 0, 0, 0 | 297, 7750, 129 | 1.94M, 1.56M, 1.97M |
| 60k: CPU (cores) | 3.97-4.15 | 3.85-4.08 | 4.40-4.75 | - |
| 45k: failed calls (of 3.8M) | 0, 0, 0 | 0, 0, 0 | 0, 0, 0 | 680k, 439k, 651k |
| 45k: CPU (cores) | 3.09-3.23 | 3.04-3.26 | 3.30-3.41 | - |

Below saturation, CPU against hg in the same pass, and futex calls per SIP
call:

| calls/s | hg (cores) | tlsf | q_malloc | futex calls per SIP call, hg / tlsf / q_malloc |
|---|---|---|---|---|
| 30k | 2.14-2.26 | +8.5% (+4.2 to +11.9) | +51.5% (+46.8 to +57.0) | 0.78-0.84 / 2.82-3.03 / 5.84-5.93 |
| 20k | 1.53-1.69 | +3.8% (-1.4 to +12.8) | +48.0% (+39.5 to +56.7) | 0.74-0.82 / 2.55-2.75 / 5.59-5.67 |
| 10k | 0.92 | +3.1% (+2.5 to +4.0) | +43.9% (+41.6 to +45.9) | 0.62-0.70 / 2.33-2.59 / 5.36-5.44 |

The guard's cost, hg with `mem_guard` 1 against 0 in the same pass: CPU
+1.9% (-0.6 to +3.2) at 60k, +0.2% (-4.5 to +6.3) at 45k, -1.0% (-3.1 to
+0.5) at 30k, -0.4% (-5.4 to +2.6) at 20k and +2.0% (0.0 to +4.6) at 10k.
Only at 10k does no pass come out below zero. In both hg arms the corruption
counters stayed at 0 and no ERROR, CRIT or BUG line was logged at any point.

## Without memory debugging

Every allocator again, with Kamailio built with `-DMEMDBG=OFF` (no
`DBG_SR_MEMORY`, no `DBG_*_MALLOC`; `mem_guard` is 0 by default in that
build), and stock master for "stock" q_malloc and f_malloc. Otherwise the
setup of the first tables, three passes.

| | hg | tlsf | f_malloc | q_malloc |
|---|---|---|---|---|
| 60k: failed calls (of 5.1M) | 0, 0, 0 | 57, 0, 8 | 4.22M, 4.25M, 4.23M | 1.75M, 1.68M, 1.67M |
| 60k: CPU (cores) | 3.79-3.90 | 4.06-4.22 | - | - |
| 45k: failed calls | 0, 0, 0 | 0, 0, 0 | 0, 0, 0 | 0, 0, 0 |
| 45k: CPU (cores) | 2.95-3.08 | 3.10-3.18 | 3.16-3.20 | 4.42-4.65 |

The stock builds: f_malloc lost 2.31M calls at 45k in one of three passes,
and q_malloc lost 29, 4 and 0. Below saturation, against hg in the same pass,
tlsf used +4.7%, +0.4% and +2.2% more CPU at 30k, 20k and 10k, f_malloc
+6.1%, +2.0% and +4.7%, and q_malloc +51.2%, +46.2% and +46.5%. Below
saturation the build with hg_malloc compiled in, running q_malloc or
f_malloc, used between 5.7% less and 4.2% more CPU per pass than the stock
build with the same manager.

So the debugging accounts for q_malloc failing at 45k, but not for the rest:
without it hg still held 60k, and q_malloc still used about half as much CPU
again below saturation.

## The highest rate hg held

hg only, the host's default page settings (transparent huge pages "always"),
with and without memory debugging; 70k
to 120k calls/s in 10k steps, then 2.5k steps near the limit, with repeats.

- 70k to 100k: no failed call (one run at each 10k step).
- 102.5k: with debugging 3 of 4 runs had no failed call (the fourth lost 42
  of 8.7M); without debugging 4 of 4.
- 105k: 2 of 3 runs without a failed call, in both builds.
- 107.5k: failed calls in every run (3 of 3) of both builds.

From 90k the socket receive buffer overflowed and sipp's retransmissions
recovered those calls. At 120k the busiest UDP receivers used 0.93-0.94 of a
core each.
