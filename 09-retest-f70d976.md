# Re-test at `f70d976` (author's fixes for the audit)

The author replied in the PR ([comment](https://github.com/kamailio/kamailio/pull/4913#issuecomment-6083694402)) that B1–B14 and the build issue are fixed. This is a re-test of the current PR head **`f70d976`** ("address reviewer Lt-Flash audit findings"), run on 2026-10-10 with the same probes and rig as before. The numbering follows [02-phase0-1-correctness.md](02-phase0-1-correctness.md) and [05-phase3abc-lifecycle.md](05-phase3abc-lifecycle.md).

**Builds:**
- Debian 13: links `-lmsgpack-c`, module md5 `e3ba403c…`.
- Ubuntu 24.04 ([rig/build/Containerfile.ubuntu24](rig/build/Containerfile.ubuntu24)): now builds and links `-lmsgpackc`, md5 `f4511cf4…`.
- Both: 0 compiler warnings in the module.

**Tarantool:** 3.8.1, listening on both `127.0.0.1:13301` and `[::1]:13301`, so the IPv6 check is a real connection.

| # | Issue | Before (`abeb653`) | Now (`f70d976`) |
|---|---|---|---|
| **B1** | Argument injection from SIP values | Call-ID `x","injected` → 2 arguments | ❌ **unchanged: still 2 arguments** (`[["string","x"],["string","injected"]]`) |
| B2 | Big result returns success with `[]` when pkg runs short | `-M 3`, 600 kB–1 MB → rc 1, `[]` | ✅ rc **-1**, logs `failed to serialize procedure result to JSON`; the next call is fine |
| B3 | Timeouts never disable a server | 6 timeouts, 0 disables | ✅ 4 timeouts, then disabled; later calls fail fast (~110 ms) |
| B4 | 0.3 s outage → ~10 s of failed calls | 9.9 s, 8,836 errors | ✅ **0.4 s** (02:30:41.602 → 42.000, Tarantool back at 41.909), 377 errors; 0 wrong answers in 20,001 |
| B5 | Malformed JSON sent anyway | `[1,` sent; `[1 2]` → `[1]` | ✅ both return -1 |
| B6 | Failed body allocation breaks the next call | next call failed | ✅ big reply → -1, the next call answers correctly |
| B7 | Build fails on Ubuntu | link error | ✅ Ubuntu 24.04 builds |
| B8 | Bare parameter coerced to a number | `0123abc@h` → `123` | ✅ `"0123abc@h"` |
| B9 | Non-ASCII `\u` dropped | `""` | ✅ `"Ж"` |
| B10 | Lua error looks like "server down" | -1 | ✅ **-2** |
| B11 | IPv4 literals only | `localhost`/`::1` → startup failure | ✅ both connect |
| B12 | Fixed 1 MiB limit | 1.1 MB → -1 | ✅ scales with pkg (`max_response_percent`): 1.1 MB OK at `-M 8`, clean -1 at `-M 2` |
| B13 | Non-SIP processes connect | 11 for 8 workers | ✅ **8** |
| B14 | Dead code | present | ✅ removed |
| **L1** | Timeout returns -1 though the procedure still runs | 8 leaked reservations per stall | ❌ **unchanged: 8 leaked per stall in 3 of 3 runs** (trunk 1 usable for 7 of 15) |
| **L2** | Greeting failures during a stall count toward disabling | yes | ❌ unchanged (15 `failed to read greeting` during the stalls) |

## Notes

- **B1:** the routing script substitutes the variables into the JSON text before the module parses it, so a value containing `","` changes the structure, however strict the parser is. The options are JSON-escaping the variable values, or passing arguments separately the way `ndb_redis` does with `%s`.
- **L1:** the new `-2` covers Lua errors (`TNT_IPROTO_ERROR`) only. A timed-out call still returns `-1`, the same as a call that never ran. A distinct code for "timed out, outcome unknown" would let scripts avoid the leak.
- **B3 in the author's table is labelled as the Unicode fix,** and the B-numbers differ in a few other rows. This table follows my report's numbering.

Raw output: [results/retest-f70d976/](results/retest-f70d976/). `pf1/` holds the probe stages and `pf3/` the stall runs.
