# Phase 4: sanitizers and soak

Run on 2026-10-03, 20:32–21:50 AEST, against the same PR head `abeb653`. The load came from the same remote SIPp generators as the Phase 2 repeats; Kamailio ran with `children=16` on 14 cores.

## Builds

| Image | Build | `ndb_tarantool.so` md5 |
|---|---|---|
| `asan-sys` | `-fsanitize=address,undefined`, **`MEMPKG=sys`** (no `-DPKG_MALLOC`, so `pkg_malloc` is libc `malloc` and ASan sees the module's heap) | `d199c396…` |
| `rel` | release, Kamailio q_malloc | `93aaecd5…` |

**Instrument check (fail-first):** a deliberate heap overflow, leak and signed overflow compiled in the same image, with the same options, produced an ASan report, a LeakSanitizer report and a UBSan `runtime error`. In this combined build, ASan and LSan reports land in the `ubsan.*` log files and UBSan reports only on stderr, which is captured in the Kamailio log. All counts below cover every file and log.

## Results

| Stage | What | Result |
|---|---|---|
| ASan probes | Phase 1 probe stages (basic, slow, big, addr, conns, restart) on the ASan build | ✅ same outcomes as the release build; **0 ASan, 0 UBSan reports** |
| ASan soak | 30 min CDR lookup at 5,000 cps, 500k rows | ✅ **9,000,000 calls, 1 failed, 0 ASan, 0 UBSan reports**; PSS 2.80 → 2.81 GB (ASan quarantine, flat over the last 29 min) |
| Release soak | 30 min CDR lookup at 5,000 cps, 500k rows | ✅ **8,993,636 calls, 0 failed**. Per-process `pkg` used, start → end: **+0 B in 13 processes, +320 B in 8** (one-time warm-up per worker). PSS flat at 19,666 kB. fds unchanged in all 21 processes. Answer key 200/200 afterwards |
| Restarts | 100 Tarantool restarts (`podman restart`, ~8 s apart) under 1,000 cps | ✅ no fd growth (all 21 processes unchanged), `pkg` used +0–256 B (one process +4,528 B), 0 wrong answers. ⚠️ **75 % of calls failed: 160,764 OK, 472,713 failed** |

**Leak checking caveat:** Kamailio worker processes exit with `_exit(0)` on SIGTERM (`core/main.c`), which skips LeakSanitizer. So the ASan runs **cannot** show leaks, and "0 leak reports" is not evidence of anything. The leak evidence here is the release build's per-process `pkg.stats` `used` deltas above, which show no growth over 9 million calls.

**Why 75 % failed in the restart stage:** 449,566 of the 472,713 failures were `cannot execute call: connection ... is down`, meaning a worker's server was marked disabled. There were 391 `marked disabled for 10 seconds` events over the 100 restarts. With a restart every ~8 s and `disable_time` 10 s, workers spend most of the stage disabled. This is bug **B4** from [02-phase0-1-correctness.md](02-phase0-1-correctness.md) under a repeated outage: each sub-second restart (Tarantool was back within ~0.3 s) costs about 10 s of failed calls per worker. The other failures were the first call on a dead socket after each restart (358 `Broken pipe` on send, 15 receive errors) and 759 refused connects.

## Bugs found in this phase

None new. No memory errors, no undefined behaviour, no fd leak, and no `pkg` growth under load. B4 was reconfirmed and quantified: repeated short outages make most calls fail (75 % at one restart per ~8 s).

## Corrections made during the run

- The first ASan restart stage was invalid: 0 answers, because the probe script didn't pass `-s cdr` after the CDR scenario's request URI was made `-s`-driven. It was fixed and re-run (`results/phase4/asan_restart/`): 10,643 answers checked, 0 wrong, 0 sanitizer reports.
- The driver's on-the-fly `pkg.stats` parser read both `used:` and `real_used:`, so its one-line summary in `results.txt` is wrong. The per-process figures above were recomputed from the saved values, and the parser is fixed in `rig/phase4.sh`.

Raw data is in [results/phase4/](results/phase4/). The restart stage's Kamailio log is gzipped (62 MB of repeated connection errors).
