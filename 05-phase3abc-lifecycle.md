### Phase 3a–c: call lifecycle (release paths) for trunk channel reservations

Same rig and routing as Phase 3. Each call reserves a channel with one backend call keyed by Call-ID, and releases it on BYE and in `failure_route`. Each run sends 120 INVITEs within 20 ms against limits 15 / 35 / 50, and holds answered calls for 5 s. **Leaked** means the reservations still held in the backend 2 s after every call had ended or failed, which should be 0.

**How each variant was produced:**
- **3a:** the trunk UAS rejects each INVITE with 486 with probability 0.1.
- **3b:** an atomic busy loop blocks the backend's main thread for 3 s: Tarantool via a console Lua loop, Redis via a `TIME`-polling `EVAL`. The burst arrives during the stall. Kamailio uses `cmd_timeout` 1000 ms on both modules.
- **3c / 3cx:** `podman kill -s KILL` on the Kamailio container 1 s into the hold. In 3c it restarts at once; in 3cx it restarts 40 s later, after the UAC has given up retransmitting BYE.

**Summary**

| Variant | Scenario | Arm | Runs | Oversold | Answered per run | 503 per run | 486 per run | **Leaked after all calls ended** |
|---|---|---|---:|---|---|---|---|---|
| 3a | trunk rejects ~10 % with 486 | `ndb_tarantool` | 10 | 0 / 10 | 91–100 | 4–15 | 5–24 | 0 |
| 3a | trunk rejects ~10 % with 486 | `ndb_redis` | 10 | 0 / 10 | 95–100 | 0–17 | 3–25 | 0 |
| 3b | backend main thread blocked 3 s (> `cmd_timeout` 1 s) during the burst | `ndb_tarantool` | 10 | 0 / 10 | 92 | 28 | 0 | **8** per run (trunks 8 / 0 / 0) |
| 3b | backend main thread blocked 3 s (> `cmd_timeout` 1 s) during the burst | `ndb_redis` | 10 | 0 / 10 | 96 | 24 | 0 | **4** per run (trunks 0 / 0 / 4) |
| 3c | `kill -9` Kamailio 1 s into the hold, restarted at once | `ndb_tarantool` | 5 | 0 / 5 | 100 | 20 | 0 | 0 |
| 3c | `kill -9` Kamailio 1 s into the hold, restarted at once | `ndb_redis` | 5 | 0 / 5 | 100 | 20 | 0 | 0 |
| 3cx | `kill -9` Kamailio, down until the BYEs give up (40 s) | `ndb_tarantool` | 2 | 0 / 2 | 100 | 20 | 0 | **100** per run (trunks 15 / 35 / 50) |
| 3cx | `kill -9` Kamailio, down until the BYEs give up (40 s) | `ndb_redis` | 2 | 0 / 2 | 100 | 20 | 0 | **100** per run (trunks 15 / 35 / 50) |

**Results**
- **3a (486 → `failure_route`):** ✅ both modules release correctly. 0 leaks in 20 runs, and no trunk ever exceeded its limit. Channels freed by rejected calls were reused by later calls in the same burst.
- **3b (backend stall longer than `cmd_timeout`):** ❌ **both modules leak, every run.** `ndb_tarantool` leaked **8** reservations per run, which matches the 8 SIP workers; `ndb_redis` leaked **4**. The pattern: Kamailio times out, replies 503 and never releases, while the request already sent still runs on the server once the stall ends. With `ndb_tarantool`, 8 of trunk 1's 15 channels stayed reserved, so only 7 calls could use it. Each such stall permanently removes capacity until something cleans it up.
- **3c (Kamailio crash, quick restart):** ✅ no leaks for either module. The reservation state lives in the backend and the release is keyed by Call-ID, so the BYEs handled by the new instance released everything.
- **3cx (Kamailio down until the BYEs give up):** ❌ every held reservation leaks for both modules (100 of 100). This is expected with no expiry on reservations; it's an application design point, not a module bug.

**Winner: tie.** Both modules behaved the same on every release path. On the one path that leaks because of request timeouts (3b), `ndb_tarantool` leaked more: 8 against 4 for the same stall, though the cause of that difference is not analysed yet.

### Bugs found in this phase

| # | Severity | Bug | Evidence | Suggested fix |
|---|---|---|---|---|
| L1 | **Medium** | A timed-out `tarantool_call` returns **-1, the same as a call that was never executed**, but the procedure may still run on the server. Scripts that reserve resources can't tell "failed" from "outcome unknown", and leak. | 3b: 8 leaked reservations in 10 of 10 runs; Kamailio log shows `failed to receive IPROTO_CALL response header ... Resource temporarily unavailable` | Return a separate code for a timeout (for example -2) and document that the outcome is unknown. The docs' reservation examples should be idempotent per Call-ID and carry an expiry. `ndb_redis` shares the ambiguity, so this is a suggestion rather than a regression. |
| L2 | Low | During a backend stall, the workers' reconnects fail at the greeting (`failed to read greeting ... Resource temporarily unavailable`). Those failures count toward `allowed_timeouts`, so a slow server gets treated like a dead one by whichever workers happen to reconnect. This adds to B3/B4 in [02-phase0-1-correctness.md](02-phase0-1-correctness.md). | 3b smoke: 5 greeting failures and 5 `connection ... is down` while the stall lasted | Covered by the B3/B4 fixes: count failures per request and per time window, not per connect |

There were no crashes, no protocol errors and no wrong answers in any of the 58 runs. B3 (a slow server never disabled) and B4 (a short outage costs `disable_time`) from [02-phase0-1-correctness.md](02-phase0-1-correctness.md) showed up again under load in 3b.

**Not a module bug, but worth a line in the docs:** 3cx shows that a reservation with no expiry leaks forever if the BYE never arrives. The README's own `billing_authorize` example sets `expires_at`; a cleanup fiber or TTL index on that field would make the example safe.

<details>
<summary><b>All data</b>: every run (58 rows)</summary>

| Variant | Arm | Run | Peak t1/15 | Peak t2/35 | Peak t3/50 | Answered | 503 | 486 | Left in backend t1 t2 t3 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| 3a | tnt | 1 | 14 | 35 | 42 | 91 | 5 | 24 | 0 0 0 |
| 3a | tnt | 2 | 15 | 35 | 50 | 100 | 15 | 5 | 0 0 0 |
| 3a | tnt | 3 | 15 | 35 | 49 | 99 | 4 | 17 | 0 0 0 |
| 3a | tnt | 4 | 15 | 35 | 50 | 100 | 7 | 13 | 0 0 0 |
| 3a | tnt | 5 | 15 | 35 | 50 | 100 | 13 | 7 | 0 0 0 |
| 3a | tnt | 6 | 15 | 35 | 50 | 100 | 7 | 13 | 0 0 0 |
| 3a | tnt | 7 | 15 | 35 | 50 | 100 | 4 | 16 | 0 0 0 |
| 3a | tnt | 8 | 15 | 35 | 50 | 100 | 14 | 6 | 0 0 0 |
| 3a | tnt | 9 | 15 | 35 | 50 | 100 | 15 | 5 | 0 0 0 |
| 3a | tnt | 10 | 15 | 35 | 50 | 100 | 9 | 11 | 0 0 0 |
| 3a | redis | 1 | 15 | 35 | 48 | 98 | 14 | 8 | 0 0 0 |
| 3a | redis | 2 | 15 | 35 | 47 | 97 | 14 | 9 | 0 0 0 |
| 3a | redis | 3 | 15 | 35 | 50 | 100 | 13 | 7 | 0 0 0 |
| 3a | redis | 4 | 15 | 35 | 50 | 100 | 16 | 4 | 0 0 0 |
| 3a | redis | 5 | 15 | 35 | 49 | 99 | 4 | 17 | 0 0 0 |
| 3a | redis | 6 | 15 | 35 | 45 | 95 | 0 | 25 | 0 0 0 |
| 3a | redis | 7 | 15 | 35 | 48 | 98 | 5 | 17 | 0 0 0 |
| 3a | redis | 8 | 15 | 35 | 50 | 100 | 17 | 3 | 0 0 0 |
| 3a | redis | 9 | 15 | 35 | 50 | 100 | 12 | 8 | 0 0 0 |
| 3a | redis | 10 | 15 | 35 | 49 | 99 | 1 | 20 | 0 0 0 |
| 3b | tnt | 1 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 2 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 3 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 4 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 5 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 6 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 7 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 8 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 9 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | tnt | 10 | 7 | 35 | 50 | 92 | 28 | 0 | 8 0 0 ⚠️ |
| 3b | redis | 1 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 2 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 3 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 4 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 5 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 6 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 7 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 8 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 9 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3b | redis | 10 | 15 | 35 | 46 | 96 | 24 | 0 | 0 0 4 ⚠️ |
| 3c | tnt | 1 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | tnt | 2 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | tnt | 3 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | tnt | 4 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | tnt | 5 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | redis | 1 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | redis | 2 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | redis | 3 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | redis | 4 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3c | redis | 5 | 15 | 35 | 50 | 100 | 20 | 0 | 0 0 0 |
| 3cx | tnt | 1 | 15 | 35 | 50 | 100 | 20 | 0 | 15 35 50 ⚠️ |
| 3cx | tnt | 2 | 15 | 35 | 50 | 100 | 20 | 0 | 15 35 50 ⚠️ |
| 3cx | redis | 1 | 15 | 35 | 50 | 100 | 20 | 0 | 15 35 50 ⚠️ |
| 3cx | redis | 2 | 15 | 35 | 50 | 100 | 20 | 0 | 15 35 50 ⚠️ |

"Left in backend" is the backend's own count of reservations on trunks 1, 2 and 3, taken 2 s after the last call ended. ⚠️ marks a run with leaked reservations.
</details>
