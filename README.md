# Test report: `ndb_tarantool` (kamailio/kamailio#4913)

Independent testing of the `ndb_tarantool` module proposed in
[kamailio/kamailio#4913](https://github.com/kamailio/kamailio/pull/4913).
Everything was tested at PR head `abeb653`, built into Kamailio 6.2.0-dev1 with gcc 14.2 on Debian 13.
Backends were Tarantool 3.8.1, 2.11.5 and 1.10.15, and Redis 8.10.1 for the comparison arms (`ndb_redis`).
SIPp drove all traffic through Kamailio, on one host over loopback, with CPU pinning.
Tests ran on 2026-10-02/03.

**Conclusion:** see the [final comment on the PR](https://github.com/kamailio/kamailio/pull/4913#issuecomment-5970209309). In short:
- These workloads gave no strong reason to move from Redis to Tarantool.
- Two good fits: a provider whose billing, CDR and other data already live in Tarantool, and lookups that need a general secondary index.
- The module works and could be useful once B1–B14 and L1–L2 are fixed.
- The PR's latency and throughput speed-ups could not be reproduced. The PR's comparison assumes Redis is used in a way it isn't designed for; used as intended, as here, Redis was on par or faster.

## Phases

| # | Report | What was tested | Outcome |
|---|---|---|---|
| — | [01-test-plan.md](01-test-plan.md) | Rig layout and the plan for all phases | — |
| 0–1 | [02-phase0-1-correctness.md](02-phase0-1-correctness.md) | Build portability, plus probes for parameters, timeouts, failover, memory, errors, addresses and connections; Tarantool 3.x / 2.11 / 1.10 | **14 bugs (B1–B14)**, 3 of them high |
| 2 | [03-phase2-throughput.md](03-phase2-throughput.md) | CDR lookup by caller at 5k and 500k rows: `ndb_tarantool` vs `ndb_redis` (ZSET, `FT.SEARCH`, full scan). One repeat | Redis ZSET used about 40 % less backend CPU per lookup; Tarantool beat `FT.SEARCH` (~2×) and the scan (~120×); throughput limited by the rig |
| 2 (repeats) | [06-phase2-repeats.md](06-phase2-repeats.md) | Same cells, 3 repeats, with the rig no longer the limit: 18 remote SIPp instances, Kamailio on 14 cores, 16 MB UDP buffers, and drops attributed per step | **`ndb_redis` ZSET 30k cps vs `ndb_tarantool` 20k cps** for CDR lookup in every repeat; Tarantool beats `FT.SEARCH` (20k vs 5k); the no-backend rig passes 50k |
| 3 | [04-phase3-trunk-limits.md](04-phase3-trunk-limits.md) | Trunk channel limits under 120 INVITEs in 20 ms, 20 runs per arm, with two must-fail controls | Tie: 0 of 20 runs oversold for both atomic designs |
| 3a–c | [05-phase3abc-lifecycle.md](05-phase3abc-lifecycle.md) | Release paths: 486, a backend stall longer than `cmd_timeout`, and `kill -9` of Kamailio | Tie; a backend stall leaks reservations on both modules (8 vs 4 per stall), giving **bugs L1, L2** |
| 4 | [07-phase4-sanitizers-soak.md](07-phase4-sanitizers-soak.md) | ASan+UBSan build with libc pkg malloc (probes + 30 min soak), 30 min release soak with per-process `pkg` and fds, 100 Tarantool restarts under load | **No memory errors, no UB, no leaks or fd growth** over 9 M calls; B4 reconfirmed: restarts every ~8 s make 75 % of calls fail |
| — | [08-latency.md](08-latency.md) | Per-call latency inside Kamailio (`benchmark` module), empty call and CDR lookup, 1k cps | `ndb_tarantool` 244 / 370 µs vs `ndb_redis` 224 / 267 µs average; Redis `FT.SEARCH` 1.8 ms |
| re-test | [09-retest-f70d976.md](09-retest-f70d976.md) | The author's fixes at PR head `f70d976` (2026-10-10): the same probes, the Ubuntu 24.04 build and the backend-stall test | **13 of 14 fixed** (B2–B14); **B1 (injection), L1 and L2 still open** |

## Bugs found

| # | Severity | Summary |
|---|---|---|
| B1 | High | Parameters built from SIP values can inject arguments (Call-ID `x","injected` becomes 2 arguments) |
| B2 | High | A big result returns success with `[]` when pkg memory runs short |
| B3 | High | Command timeouts never disable a server |
| B4 | Medium | A 0.29 s outage causes about 9.9 s of failed calls (`disable_time` on every worker) |
| B5 | Medium | Malformed JSON params are sent anyway or truncated silently |
| B6 | Medium | A failed body allocation leaves the reply on the socket; the next call fails, logged with a stale errno |
| B7 | Medium | Build fails on Ubuntu 20.04 and 24.04 (msgpack naming) |
| B8–B12 | Low | Bare parameters coerced to numbers; non-ASCII `\u` escapes dropped; a Lua error looks the same as "server down"; IPv4 literals only; undocumented 1 MiB result limit |
| B13–B14 | Info | Non-SIP processes connect too; dead code |
| L1 | Medium | A timed-out call returns -1 although the procedure may still run, so reservations leak |
| L2 | Low | Greeting failures during a stall count toward disabling the server |

Details, reproduction steps and suggested fixes are in the per-phase reports.

## Layout

- `rig/`: everything needed to reproduce:
  - `tarantool/init.lua`, the Tarantool schema and procedures
  - `redis/voipbench.lua`, the Redis Functions
  - `kamailio/*.cfg`
  - `sipp/*.xml`
  - `gen_cdr.py`, which generates the dataset and its answer key
  - `build/Containerfile`
  - the drivers `phase1.sh`, `phase2.sh`, `phase3.sh`, `phase4.sh`, `gen.sh` (remote SIPp helper) and `up.sh`

  The scripts expect to run from `/var/tmp/ndbt` with podman.
- `results/`: raw output (`results.tsv` per phase, driver logs, Kamailio logs, SIPp logs).

Host addresses are replaced by placeholders throughout: `SUT_IP` (the Kamailio + backend host), and `GEN_A` / `GEN_B` (the SIPp load generators).
