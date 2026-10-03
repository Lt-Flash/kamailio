### Phase 3: trunk channel limits under concurrent INVITEs

**Setup** (same rig as Phase 2):
- Kamailio (master + this PR `abeb653`, `children=8`) relays each INVITE statefully (`tm`) to one of three trunk UAS (SIPp).
- Before relaying, it reserves a channel with a single backend call keyed by Call-ID; it releases the channel on BYE and in `failure_route`.
- Trunk limits are **15 / 35 / 50** (100 channels). Each run sends **120 INVITEs within 20 ms**, holds every answered call for 5 s, then sends BYE. So 20 calls must get 503.
- **Ground truth** is the actual peak of simultaneous answered calls on each trunk, taken from the trunk UAS logs, not the backend's own counters.
- **20 runs per arm**, with counters reset before each run.

**Arms:**
- `ndb_tarantool`: `tarantool_call("lcr_acquire", "[\"$ci\"]", ...)`. This is a memtx procedure: count by a secondary index `by_trunk`, then insert, with no yield in between.
- `ndb_redis`: `FCALL lcr_acquire` (`SCARD` + `SADD` + `HSET` inside one Redis Function).
- Control 1: `ndb_redis` with `SCARD`, a compare in the script, then `SADD` (two round trips). This is expected to oversell.
- Control 2: the same Tarantool procedure with `fiber.sleep(0.001)` between count and insert. This is also expected to oversell.

The two controls exist to prove the rig can detect overselling, so they are supposed to fail.

**Summary (20 runs per arm, 2,400 calls per arm)**

| Arm | Runs oversold | Worst peak, trunks 1 / 2 / 3 | Extra calls per run (min / avg / max) | 503 per run | Reservations left after BYE |
|---|---|---|---|---|---|
| `ndb_tarantool` (stored procedure) | ✅ **0 / 20** | 15 / 35 / 50 | 0 / 0 / 0 | 20 every run | 0 |
| `ndb_redis` (Redis Function) | ✅ **0 / 20** | 15 / 35 / 50 | 0 / 0 / 0 | 20 every run | 0 |
| `ndb_redis` read-then-write in the script (control) | ❌ 19 / 20 | 18 / 39 / 54 | 0 / 4.4 / 8 | 12–20 | 0 |
| `ndb_tarantool` proc with a yield inside (control) | ❌ 20 / 20 | 22 / 41 / 56 | 8 / 11.8 / 16 | 4–12 | 0 |

**Winner: tie.** Both `ndb_tarantool` and `ndb_redis` with an atomic server-side function held every trunk exactly at its limit in all 20 runs. Neither left a reservation behind, and neither logged an error. Overselling only appeared when the check and the reservation were split, either into two client round trips or into a Tarantool procedure that yields between them. The guarantee comes from doing the check and the reservation in one atomic server-side step, which both backends provide.

### Bugs found in this phase

None in `ndb_tarantool`: 2,400 calls in the main arm, 0 Kamailio errors or warnings, and 0 leaked reservations.

Not covered yet: the call-lifecycle cases from the plan, namely release after a 486, after a backend stall longer than `cmd_timeout`, and after `kill -9` of Kamailio. From bug B3 in [02-phase0-1-correctness.md](02-phase0-1-correctness.md), a timed-out `lcr_acquire` can still run on the server while Kamailio replies 503, which would leak a channel. That case is next.

<details>
<summary><b>All data</b>: every run of every arm (80 rows)</summary>

| Arm | Run | Trunk 1 peak / 15 | Trunk 2 peak / 35 | Trunk 3 peak / 50 | 503 | Left in backend | Verdict |
|---|---:|---:|---:|---:|---:|---|---|
| tnt | 1 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 2 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 3 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 4 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 5 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 6 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 7 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 8 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 9 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 10 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 11 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 12 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 13 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 14 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 15 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 16 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 17 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 18 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 19 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| tnt | 20 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 1 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 2 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 3 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 4 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 5 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 6 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 7 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 8 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 9 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 10 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 11 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 12 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 13 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 14 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 15 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 16 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 17 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 18 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 19 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| redis | 20 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| naive | 1 | 15 | 35 | 50 | 20 | 0 0 0 | ✅ |
| naive | 2 | **16** | 35 | **51** | 18 | 0 0 0 | ❌ oversold |
| naive | 3 | **16** | **36** | **52** | 16 | 0 0 0 | ❌ oversold |
| naive | 4 | **18** | **37** | **52** | 13 | 0 0 0 | ❌ oversold |
| naive | 5 | **17** | 35 | 50 | 18 | 0 0 0 | ❌ oversold |
| naive | 6 | **18** | **38** | 50 | 14 | 0 0 0 | ❌ oversold |
| naive | 7 | **16** | **38** | **51** | 15 | 0 0 0 | ❌ oversold |
| naive | 8 | **17** | 35 | 50 | 18 | 0 0 0 | ❌ oversold |
| naive | 9 | **17** | **39** | **51** | 13 | 0 0 0 | ❌ oversold |
| naive | 10 | 15 | **38** | 50 | 17 | 0 0 0 | ❌ oversold |
| naive | 11 | **16** | **36** | 50 | 18 | 0 0 0 | ❌ oversold |
| naive | 12 | **16** | **36** | 50 | 18 | 0 0 0 | ❌ oversold |
| naive | 13 | **16** | 35 | **51** | 18 | 0 0 0 | ❌ oversold |
| naive | 14 | **18** | **38** | **52** | 12 | 0 0 0 | ❌ oversold |
| naive | 15 | **16** | **37** | **54** | 13 | 0 0 0 | ❌ oversold |
| naive | 16 | **17** | **37** | **53** | 13 | 0 0 0 | ❌ oversold |
| naive | 17 | **17** | **39** | 50 | 14 | 0 0 0 | ❌ oversold |
| naive | 18 | **16** | **38** | 50 | 16 | 0 0 0 | ❌ oversold |
| naive | 19 | **18** | **36** | **51** | 15 | 0 0 0 | ❌ oversold |
| naive | 20 | **17** | **37** | **53** | 13 | 0 0 0 | ❌ oversold |
| yield | 1 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 2 | **16** | **36** | **56** | 12 | 0 0 0 | ❌ oversold |
| yield | 3 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 4 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 5 | **22** | **38** | **56** | 4 | 0 0 0 | ❌ oversold |
| yield | 6 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 7 | **16** | **41** | **54** | 9 | 0 0 0 | ❌ oversold |
| yield | 8 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 9 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 10 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 11 | **18** | **40** | **56** | 6 | 0 0 0 | ❌ oversold |
| yield | 12 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 13 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 14 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 15 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 16 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 17 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 18 | **16** | **40** | **52** | 12 | 0 0 0 | ❌ oversold |
| yield | 19 | **19** | **37** | **56** | 8 | 0 0 0 | ❌ oversold |
| yield | 20 | **16** | **40** | **56** | 8 | 0 0 0 | ❌ oversold |

Peaks above the limit are in bold. "Left in backend" is the backend's own count of reservations on trunks 1 2 3 about 1 s after the last BYE.
</details>
