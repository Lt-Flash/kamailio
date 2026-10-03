# Per-call latency: `ndb_tarantool` vs `ndb_redis`

Run on 2026-10-04 against PR head `abeb653` (release build, module md5 `93aaecd5…`).

**Method:** Kamailio's `benchmark` module wraps **only the module call** (`tarantool_call` / `redis_cmd`) inside the SIP worker, so each value is the latency a routing script sees: module, socket round trip and server time. The setup:
- 16 workers on 14 cores; the backend alone on 2 cores.
- Loopback, light load: 1,000 cps from SIPp on the same host, 20,000 calls per case. Every case had 0 failed calls.
- The figures are the module's global statistics over the run (first 1,000 calls excluded by its granularity).
- Config: [rig/kamailio/lat.cfg](rig/kamailio/lat.cfg) (the bench config plus `bm_start_timer` / `bm_log_timer` around the call).

| Case | Data | Avg | Min | Max |
|---|---|---:|---:|---:|
| `ndb_tarantool` empty call (`noop`) | — | **244 µs** | 107 µs | 3.1 ms |
| `ndb_redis` empty call (`FCALL noop`) | — | **224 µs** | 108 µs | 1.7 ms |
| `ndb_tarantool` CDR lookup (TREE index on `(src, ts)`) | 5k rows | **370 µs** | 132 µs | 4.7 ms |
| `ndb_redis` CDR lookup (ZSET per caller, Redis Function) | 5k rows | **267 µs** | 118 µs | 1.5 ms |
| `ndb_redis` CDR lookup (Redis 8 `FT.SEARCH`, TAG index) | 5k rows | **1,768 µs** | 216 µs | 80 ms |

## Against the latency figures in the PR

| PR | Measured |
|---|---|
| Tarantool 0.1–0.3 ms per call | 0.24 ms (empty call), 0.37 ms (CDR lookup) average; ~0.11–0.13 ms best case |
| Redis 0.5–2 ms per call | 0.22 ms (empty call), 0.27 ms (CDR lookup, sorted set) average. Only `FT.SEARCH` (1.8 ms) falls in that range |
| Stored procedure call under 150 µs | best case 107–132 µs; average 244–370 µs as seen from Kamailio |

This was one run per case. The 20 µs difference between the two empty calls is within run-to-run noise. The difference between Redis at ~0.25 ms and the 0.5–2 ms quoted for Redis is not.

Raw data: [results/latency/](results/latency/) (Kamailio logs with the `benchmark` lines, SIPp stats).
