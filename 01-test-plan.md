### Test plan for `ndb_tarantool`

Everything runs on one host over loopback, with CPU pinning so each side gets the same cores:

| Role | Cores | Notes |
|---|---|---|
| Tarantool **or** Redis, one at a time | 0-1 | Persistence matched per cell: Redis without save/AOF with Tarantool `wal_mode=none`, or AOF everysec with WAL `write` |
| Kamailio (master + this PR, `children=8`) | 4-9 | one config file; the backend is chosen with `-A WITH_TNT / WITH_REDIS / ...` |
| SIPp | 10-13 | |

Every arm does **one round trip and returns the same shape** (the newest 20 CDR ids as one string). All arms are first checked against one answer key; an arm that returns wrong rows is excluded.

| Phase | What | Arms | Measured |
|---|---|---|---|
| 0 | Build | normal + ASan/UBSan | :white_check_mark: done |
| 1 | Correctness probes | see [02-phase0-1-correctness.md](02-phase0-1-correctness.md) | :white_check_mark: done |
| 2 · S0 | Transport floor: no backend, and an empty call | none, `tarantool_call("noop")`, `ndb_redis FCALL noop` | highest step meeting p99 < 10 ms, CPU per 1k requests (Kamailio and backend) |
| 2 · S1 | CDR history by caller, at 5k / 500k / 2M rows | Tarantool TREE index `(src, ts)`; Redis ZSET per caller (Function, 1 RTT); Redis 8 Query Engine `FT.SEARCH` TAG; Redis full `LRANGE` scan (baseline) | p50 / p99 / p99.9, highest step meeting the SLO, CPU per 1k requests |
| 2 · S2 | 50 concurrent callers, closed loop | Tarantool vs Redis | cps, latency |
| 3 | Trunk channel limits (15 / 35 / 50), 120 concurrent INVITEs, calls held 5 s | Tarantool proc; Redis Function (atomic); read-then-write from the script (expected to oversell); Tarantool proc with a yield inside (expected to oversell) | actual peak of simultaneous calls on each trunk, counted at the trunk UAS; 20 runs per arm |
| 3a-c | Call lifecycle | the same arms | channels leaked after 486 replies, after a backend stall longer than `cmd_timeout`, and after `kill -9` of Kamailio |
| 4 | Sanitizers + soak | ASan build, 30 min at 50 % load, repeated backend restarts | ASan/UBSan reports, pkg usage per process, fd count per worker |

The two expected-to-oversell arms are there to prove the rig can detect overselling, so they must fail. Throughput results are reported as the highest load step that meets the SLO, together with CPU per request, not as peak QPS.
