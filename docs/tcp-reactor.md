# hg_malloc under the TCP reactor

With `tcp_main_threads=2` the TCP main process runs a pool of threads next
to its io_wait thread, and they share that process's pkg memory. For the
managers that are not thread-safe (q_malloc, f_malloc, tlsf) the reactor
wraps every pkg call in a mutex (`tcp_reactor_pkg_lock_install()`,
`src/core/tcp_reactor_mem.c`); for `sm` (the libc allocator) it installs
none. hg_malloc is in the second group: `tcp_reactor_pkg_lock_install()`
returns before wrapping anything when the pkg manager is `hg_malloc`, because
an allocation and the free that returns it touch only the calling thread's
own cache (design.md, sections 6 and 9), and the pool threads flush their
caches at job boundaries (`tcp_reactor_thread_routine()`). This page is the
test of that: the reactor under TCP load with hg serving pkg and no mutex,
against the same load with q_malloc (mutex) and sm (no mutex, no pool)
serving pkg.

## Test setup

The build and host of [why-hg-holds.md](why-hg-holds.md): Kamailio master
(e41867c) with hg_malloc, cmake with the distribution's hardened flags,
memory debugging on (`MEMDBG=1`), a 16 vCPU virtual machine. The same tm
mode config (an INVITE that tm answers with 486, then the ACK; 8 workers),
with TCP enabled:

```
disable_tcp=no
listen=udp:10.22.20.224:5070
listen=tcp:10.22.20.224:5070
tcp_main_threads=2
tcp_reactor_threads=8
tcp_async=yes
tcp_accept_no_cl=yes
tcp_connection_lifetime=60
tcp_max_connections=8192
open_files_limit=16384
```

That gives 23 processes, and a TCP main process of 9 threads (io_wait plus
8 pool threads), read from `/proc/<pid>/task` before and after every point.
The load: 16 sipp instances on two hosts, each holding one TCP connection
to Kamailio (`-t t1`) for the whole point and sending its share of the rate
on it, 85 s per point. hg serves shm in every arm (`-x hg`); the pkg manager
is the arm: `-X hg -M 8:64`, `-X qm -M 64`, or `-X sm`. The shm arena is
`-m 64:256` up to 4k calls/s and `-m 512:4096` at 8k.

The reactor's own decision, read from the start log at debug level 3, one
start per arm:

```
-X hg: tcp_reactor_pkg_lock_install(): pkg manager is hg; reactor pkg lock not needed
-X qm: tcp_reactor_pkg_lock_install(): reactor: PROC_TCP_MAIN pkg allocator serialized for the io_wait and pool threads
-X sm: tcp_reactor_pkg_lock_install(): pkg manager is sm (system malloc); reactor pkg lock not needed
```

## Results

Calls are the sipp totals over both hosts; CPU is the Kamailio processes'
user plus system time over the point (about 88 s from launch to the last
call). "Failed" counts calls sipp gave up on;
every failure below was a closed connection after Kamailio refused the
transaction for lack of shm.

| calls/s | shm | pkg | calls | failed | retransmissions | CPU, s | ms per call | log CRIT/ERROR | hg corruption |
|---|---|---|---|---|---|---|---|---|---|
| 1000 | -m 64:256 | hg | 81600 | 0 | 0 | 40.7 | 0.499 | 0 / 0 | 0 |
| 2000 | -m 64:256 | hg | 170000 | 0 | 0 | 72.3 | 0.425 | 0 / 0 | 0 |
| 4000 | -m 64:256 | hg | 340000 | 0 | 0 | 117.1 | 0.344 | 0 / 0 | 0 |
| 4000 | -m 64:256 | qm | 340000 | 0 | 0 | 117.7 | 0.346 | 0 / 0 | 0 |
| 4000 | -m 64:256 | sm | 340000 | 0 | 0 | 114.9 | 0.338 | 0 / 0 | 0 |
| 8000 | -m 512:4096 | hg | 680000 | 0 | 0 | 205.6 | 0.302 | 0 / 0 | 0 |
| 8000 | -m 512:4096 | qm | 680000 | 0 | 0 | 207.0 | 0.304 | 0 / 0 | 0 |
| 8000 | -m 512:4096 | sm | 680000 | 0 | 0 | 205.9 | 0.303 | 0 / 0 | 0 |
| 8000 | -m 64:256 | hg | 680000 | 111442 | 0 | 194.6 | | 0 / 334331 | 0 |
| 8000 | -m 64:256 | qm | 680000 | 111563 | 0 | 195.0 | | 0 / 334694 | 0 |

At 8k calls/s with `-m 64:256` the shm arena reached its 256 MB cap
(`grow_refuse_reason: cap`) and tm could not build its transactions
(`build_cell(): could not allocate shared memory`, `new_t(): out of mem`);
hg and q_malloc pkg lost the same share, since the shortage is in shm, which
hg serves in both. The two rows are kept as the symmetric control; with
`-m 512:4096` the arena stayed at its 512 MB INIT and no call failed.

The pkg manager does not show in the CPU: at 4k the three arms are within
2.5% of each other, at 8k within 1%. The TCP main process's pkg traffic in
this load is one job struct per read and per write, so the mutex q_malloc
pays for is uncontended and cheap, and hg's and sm's absence of it is worth
the same.

## What the threads did

A 30 s CPU sample of the TCP main process at 8k calls/s with hg pkg
(1999 Hz, 77330 samples) puts all nine threads in hg's code at once: the
io_wait thread 458 of its 19277 samples in `hg_*` functions, each of the
eight pool threads 80 to 122 of its 7240 to 7280. A second sample with call
graphs (199 Hz, 15 s, 3890 samples) names the callers:

- the pool threads allocate in `tcp_reactor_dispatch_msg()`, called from
  `tcp_read_req()`: the task that carries a received message to a worker
  (shm), and free in `tcp_reactor_run_write()`: the write-queue chunks they
  have sent (shm); `hg_cache_flush_if_due()` runs at their job boundaries;
- the io_wait thread allocates the job per read and write in
  `tcp_reactor_enqueue_job()` (pkg) and the write-queue chunks in
  `tcp_reactor_wsq_add()` (shm), and frees the jobs in
  `tcp_reactor_handle_done()`.

So in this traffic the pool threads' allocations are from shm and the
io_wait thread's from pkg and shm, all through the same per-thread caches
and without the reactor's mutex; the pkg calls a pool thread makes on its
own, the frees of `TCP_R_RUN` jobs that carry a tcpx task (tls reloads and
the like), do not occur in this load. A load that makes the pool threads
allocate pkg themselves was not run; for hg the two arenas go through the
same cache code, and the thread test described in the pull request (20
short-lived threads allocating and freeing shm cells at once, none left
behind) exercises that code.

## Open point

The reactor recognises a thread-safe pkg manager by its name, as it does
for `sm`. A flag in `sr_pkg_api_t` would serve any future manager without
touching the reactor; it is listed in design.md, section 15.
