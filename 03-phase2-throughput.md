### Phase 2 (quick pass): CDR lookup throughput, `ndb_tarantool` vs `ndb_redis`

> **Update:** the throughput ceilings in this one-repeat pass were limited by the rig (UDP receive-buffer overflow on the load host). See [06-phase2-repeats.md](06-phase2-repeats.md) for 3 repeats with the rig out of the way. The CPU-per-lookup figures here still agree with the repeats.

These are the first throughput results. This is **one repeat**, so please treat it as preliminary; repeats are below under next steps.

**Winner (preliminary)**

| What was measured | Winner | Margin |
|---|---|---|
| Backend CPU per lookup, against a per-caller index (ZSET) | **`ndb_redis`** | 51–53 µs vs 83–92 µs (about 40 % less) |
| Backend CPU per lookup, against a general secondary index (`FT.SEARCH`) | **`ndb_tarantool`** | 83–92 µs vs 152–207 µs (about 2× less) |
| Backend CPU per lookup, against a full-list scan | **`ndb_tarantool`** | about 120× less; the scan fails at 500k rows |
| Throughput (highest step passed) | tie | both are limited by the test rig (10k–20k cps), not by the backend |
| Kamailio CPU per call | tie | within 5 % |
| Correctness | tie | 200/200 on every arm |

In short: when the access path is known up front and kept as a per-caller ZSET, Redis was cheaper per lookup. For an ad-hoc secondary index, Tarantool was cheaper than Redis 8's Query Engine. Index maintenance cost on writes is not measured yet.

**Setup:** one host, loopback, CPU-pinned.

| Part | Setting |
|---|---|
| Backend | cores 0-1, one backend at a time: Tarantool 3.8.1 (`wal_mode=none`) or Redis 8.10.1 (no save/AOF, `io-threads 2`) |
| Kamailio | master + this PR (`abeb653`) on cores 4-9, `children=8`; requests answered statelessly after one backend call |
| SIPp | cores 10-13; INVITEs with random callers |
| Load | 40 s per step (1k, 2k, 5k, 10k, 20k cps). A step passes if ≥ 95 % of calls complete, ≤ 0.1 % fail and p99 ≤ 10 ms |
| CPU | utime+stime, sampled from 10 to 35 s of each step and divided by the calls completed in that window. "Backend" is the whole Tarantool or Redis process, all threads |
| Correctness | before loading each arm, 200 callers are checked against an answer key; all arms returned 200/200 except where noted |

**Arms.** Each makes one round trip and returns the newest 20 CDR ids of the calling number:
- `ndb_tarantool`: `tarantool_call("cdr_by_src", ...)` over a TREE index `(src, ts)`
- `ndb_redis` ZSET: a sorted set per caller, read by a Redis Function (`FCALL cdr_by_src`, `ZREVRANGE`)
- `ndb_redis` `FT.SEARCH`: the Redis 8 Query Engine, TAG index on `src`, sorted by `ts`
- `ndb_redis` scan: `LRANGE` over one list of JSON CDRs, filtered in Lua (a baseline)
- S0: an empty call to each backend, plus a run with no backend call at all (the rig ceiling)

**Summary, at 5,000 cps** (the highest step every fast arm passed):

| | Rows | Backend CPU / lookup | Kamailio CPU / call | Highest step passed |
|---|---:|---:|---:|---|
| no backend call | — | — | 130 µs | 10k |
| `ndb_tarantool` noop | — | 45 µs | 190 µs | 10k |
| `ndb_redis` noop | — | 39 µs | 184 µs | 10k |
| `ndb_tarantool` | 5k | 83 µs | 198 µs | 5k (10k: 0.28 % failed) |
| `ndb_redis` ZSET | 5k | 51 µs | 190 µs | 10k |
| `ndb_redis` `FT.SEARCH` | 5k | 152 µs | 194 µs | 5k |
| `ndb_redis` scan | 5k | 9,861 µs | — | 100 cps |
| `ndb_tarantool` | 500k | 92 µs | 201 µs | 5k (10k: 0.32 % failed) |
| `ndb_redis` ZSET | 500k | 53 µs | 187 µs | 10k |
| `ndb_redis` `FT.SEARCH` | 500k | 207 µs | 192 µs | 5k |
| `ndb_redis` scan | 500k | > 1 s per lookup | — | none |

**Observations**
- With a per-caller index on the Redis side, Redis used about 40 % less backend CPU per lookup than Tarantool (51–53 µs against 83–92 µs). Both stayed flat from 5k to 500k rows.
- A large gap in Tarantool's favour (about 120× CPU per lookup, a ceiling of about 100 lookups/s at 5k rows, and more than 1 s per lookup at 500k rows) only appears against the full-list scan.
- Kamailio's own CPU per call is within 5 % between the two modules.
- **Limits of this pass:**
  - The rig caps out between 10k and 20k cps even with no backend call (42 % failed at 20k), so the highest step passed doesn't separate the fast arms yet.
  - The 10k failures for `ndb_tarantool` (0.28 % and 0.32 %, against a 0.1 % limit) come from a single repeat.
  - SIPp reports response times only to 1 ms, so every arm below the ceiling shows p99 ≤ 1 ms.

**Next:** raise the ceiling with a second load generator, add finer steps between 10k and 20k, and run 3 repeats. After that, the trunk channel-limit tests (Phase 3 of the plan).

<details>
<summary><b>All data</b>: every step of every arm (44 rows)</summary>

| Cell | Arm | Offered cps | Offered | OK | Failed | p99 (ms) | Kamailio CPU µs/call | Backend CPU µs/call | Verdict |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| S0 | no backend call | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 185 | 4 | ✅ |
| S0 | no backend call | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 162 | 1 | ✅ |
| S0 | no backend call | 5,000 | 200,000 | 200,000 | 0 | 1.000 | 130 | 1 | ✅ |
| S0 | no backend call | 10,000 | 400,000 | 399,913 | 87 | 1.000 | 116 | 0 | ✅ |
| S0 | no backend call | 20,000 | 800,000 | 463,140 | 336,860 | 1.000 | 144 | 0 | ❌ |
| S0 | ndb_tarantool `noop` | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 254 | 83 | ✅ |
| S0 | ndb_tarantool `noop` | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 229 | 54 | ✅ |
| S0 | ndb_tarantool `noop` | 5,000 | 200,000 | 200,000 | 0 | 1.000 | 190 | 45 | ✅ |
| S0 | ndb_tarantool `noop` | 10,000 | 400,000 | 399,931 | 69 | 1.000 | 171 | 45 | ✅ |
| S0 | ndb_tarantool `noop` | 20,000 | 800,000 | 571,812 | 228,188 | 1.000 | 206 | 60 | ❌ |
| S0 | ndb_redis `FCALL noop` | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 242 | 74 | ✅ |
| S0 | ndb_redis `FCALL noop` | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 220 | 45 | ✅ |
| S0 | ndb_redis `FCALL noop` | 5,000 | 200,000 | 200,000 | 0 | 1.000 | 184 | 39 | ✅ |
| S0 | ndb_redis `FCALL noop` | 10,000 | 400,000 | 399,825 | 175 | 1.000 | 166 | 36 | ✅ |
| S0 | ndb_redis `FCALL noop` | 20,000 | 800,000 | 516,577 | 283,423 | 1.000 | 226 | 54 | ❌ |
| S1a | ndb_tarantool | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 262 | 136 | ✅ |
| S1a | ndb_tarantool | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 241 | 101 | ✅ |
| S1a | ndb_tarantool | 5,000 | 200,000 | 200,000 | 0 | 1.000 | 198 | 82 | ✅ |
| S1a | ndb_tarantool | 10,000 | 400,000 | 398,889 | 1,111 | 1.000 | 175 | 76 | ❌ |
| S1a | ndb_redis (ZSET function) | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 246 | 91 | ✅ |
| S1a | ndb_redis (ZSET function) | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 226 | 60 | ✅ |
| S1a | ndb_redis (ZSET function) | 5,000 | 200,000 | 200,000 | 0 | 1.000 | 190 | 51 | ✅ |
| S1a | ndb_redis (ZSET function) | 10,000 | 400,000 | 399,794 | 206 | 1.000 | 168 | 47 | ✅ |
| S1a | ndb_redis (ZSET function) | 20,000 | 800,000 | 404,601 | 395,399 | 1.000 | 267 | 87 | ❌ |
| S1a | ndb_redis (`FT.SEARCH`) | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 258 | 235 | ✅ |
| S1a | ndb_redis (`FT.SEARCH`) | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 237 | 185 | ✅ |
| S1a | ndb_redis (`FT.SEARCH`) | 5,000 | 200,000 | 200,000 | 0 | 1.000 | 194 | 152 | ✅ |
| S1a | ndb_redis (`FT.SEARCH`) | 10,000 | 400,000 | 379,912 | 20,088 | 1.000 | 163 | 148 | ❌ |
| S1a | ndb_redis (full `LRANGE` scan) | 100 | 4,000 | 3,996 | 4 | 1.000 | 254 | 9861 | ✅ |
| S1a | ndb_redis (full `LRANGE` scan) | 200 | 8,000 | 4,851 | 3,149 | 1.000 | 267 | 10039 | ❌ |
| S1b | ndb_redis (ZSET function) | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 251 | 97 | ✅ |
| S1b | ndb_redis (ZSET function) | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 224 | 63 | ✅ |
| S1b | ndb_redis (ZSET function) | 5,000 | 200,000 | 200,000 | 0 | 1.000 | 187 | 52 | ✅ |
| S1b | ndb_redis (ZSET function) | 10,000 | 400,000 | 399,608 | 392 | 1.000 | 169 | 54 | ✅ |
| S1b | ndb_redis (ZSET function) | 20,000 | 800,000 | 331,338 | 468,662 | 1.000 | 328 | 119 | ❌ |
| S1b | ndb_redis (`FT.SEARCH`) | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 257 | 275 | ✅ |
| S1b | ndb_redis (`FT.SEARCH`) | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 237 | 219 | ✅ |
| S1b | ndb_redis (`FT.SEARCH`) | 5,000 | 200,000 | 199,980 | 20 | 1.000 | 192 | 207 | ✅ |
| S1b | ndb_redis (`FT.SEARCH`) | 10,000 | 400,000 | 289,602 | 110,398 | 1.000 | 169 | 208 | ❌ |
| S1b | ndb_tarantool | 1,000 | 40,000 | 40,000 | 0 | 1.000 | 268 | 154 | ✅ |
| S1b | ndb_tarantool | 2,000 | 80,000 | 80,000 | 0 | 1.000 | 247 | 115 | ✅ |
| S1b | ndb_tarantool | 5,000 | 200,000 | 200,000 | 0 | 1.000 | 201 | 92 | ✅ |
| S1b | ndb_tarantool | 10,000 | 400,000 | 398,707 | 1,293 | 1.000 | 173 | 85 | ❌ |
| S1b | ndb_redis (full `LRANGE` scan) | — | — | — | — | — | — | — | gate failed: 0/20 answers (each lookup > 1 s, `cmd_timeout`) |

Notes: CPU values are µs per completed call within the sampling window. At low rates they include idle polling, so compare arms at the same rate. Each `ndb_tarantool` and `ndb_redis` arm ran under the same Kamailio image; only the `-A` define differs. The first 500k run of `ndb_tarantool` was discarded: my data loader tripped Tarantool 3's fiber-slice limit, and the arm was re-run once the loader was fixed.
</details>

The scripts and configs are in [rig/](rig/).
