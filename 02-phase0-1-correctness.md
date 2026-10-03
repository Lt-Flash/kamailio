Tested: kamailio/kamailio#4913, the rework of kamailio/kamailio#4898. Moving the connections to `child_init` and switching to pkg allocators fixes the main points from kamailio/kamailio#4898.

Probe results are in the first table, and each failure is listed once under **Bugs found** below.

I tested PR head `abeb653` on Kamailio 6.2.0-dev1 with gcc 14.2, against Tarantool 3.8.1, 2.11.5 and 1.10.15. The probes were driven by SIPp.

| # | Area | Probe | Expected | Result |
|---|---|---|---|---|
| B | Build | Ubuntu 20.04 / 24.04 | builds | :x: link fails: these ship `msgpack.pc` / `libmsgpackc`, and the fallback `-lmsgpack-c` doesn't exist there. Builds on Debian 13 (`msgpack-c` 6.x) |
| 1 | Params | Call-ID `x","injected` with the documented `"[\"$ci\"]"` | 1 string argument | :x: **2 arguments** (`"x"`, `"injected"`). A Call-ID may legally contain `"` |
| 2 | Params | bare `"$ci"`, Call-ID `0123abc@h` | 1 string argument | :x: integer `123` |
| 3 | Params | `"Ж"` | `"Ж"` | :x: `""` (non-ASCII `\u` escapes are dropped) |
| 4 | Params | `[1,` and `[1 2]` | rejected | :x: `[1,` is sent anyway (Tarantool: `Invalid MsgPack - packet body`); `[1 2]` is sent as `[1]`. The return value of `tnt_pack_params_tuple` is ignored (tarantool_client.c:1149) |
| 5 | Timeouts | 6 timeouts, `cmd_timeout=300`, `allowed_timeouts=3` | disabled after 3 | :x: never disabled; every call waits the full timeout, then reconnects. `consecutive_errors` is reset on each reconnect (tarantool_client.c:584) |
| 6 | Failover | Tarantool restart, 0.29 s down, at 1k cps | brief errors | :warning: **~9.9 s of failed calls**: all workers reach 3 fast connect failures, then wait out `disable_time` (10 s) |
| 7 | Memory | large result with `-M 3` (600 kB–1 MB) | error | :x: **rc 1 with `[]`**: the JSON conversion fails silently (tarantool_client.c:820-828) |
| 7b | Memory | large result with `-M 2` | error, socket usable | :x: the body `pkg_malloc` fails and the reply is left on the socket, so the **next, unrelated call fails**, logged with a stale errno (`Connection refused`) |
| 8 | Errors | Lua `error()` vs server down | distinguishable | :warning: both return -1 |
| 9 | Config | `addr=localhost` / `addr=::1` | resolves | :x: `invalid IPv4 address`, and Kamailio exits |
| 10 | Connections | `children=8` | 8 per server | :information_source: 11 (non-SIP processes connect too) |
| 11 | Auth | right / wrong password on 3.x, 2.11, 1.10 | accept / reject | :white_check_mark: |
| 12 | Results | 20,642 lookups checked across restarts | correct | :white_check_mark: 0 wrong |
| 13 | Limits | 1.1 MB response | rejected cleanly | :white_check_mark: |
| 14 | Build | compiler warnings | none | :white_check_mark: 0 |

### Bugs found

| # | Severity | Bug | Where | Reproduce | Suggested fix |
|---|---|---|---|---|---|
| B1 | **High** (security) | Parameters built from SIP values are spliced into JSON text, so a header can add or reorder procedure arguments | design of `params` (string JSON) | `tarantool_call("echo", "[\"$ci\"]", ...)` with Call-ID `x","injected` → 2 arguments | pass arguments separately (like `ndb_redis` `%s`), or JSON-escape PV values |
| B2 | **High** | A big result returns **success with `[]`** when the JSON buffer can't grow | `tnt_mp_to_json_str`, tarantool_client.c:820-828 | `kamailio -M 3`, procedure returning 600 kB–1 MB → rc 1, value `[]` | return -1 and log the error |
| B3 | **High** | Command timeouts never disable a server, so every call to a slow server waits the full `cmd_timeout` | `consecutive_errors = 0` in `tnt_conn_connect`, tarantool_client.c:584 | 6 × `fiber.sleep(2)` with `cmd_timeout=300`, `allowed_timeouts=3` → never disabled | reset the counter only after a successful request, not on connect |
| B4 | Medium | A sub-second outage disables every worker for the full `disable_time` | `tnt_conn_fail` / per-process counters | 0.29 s Tarantool restart at 1k cps → about 9.9 s of failed calls | probe-reconnect before disabling, or count by time window |
| B5 | Medium | Malformed JSON params are sent anyway or truncated silently | return value of `tnt_pack_params_tuple` ignored, tarantool_client.c:1149 | `[1,` → Tarantool `Invalid MsgPack`; `[1 2]` → sent as `[1]` | validate params and fail with -1 before sending |
| B6 | Medium | A failed body allocation leaves the reply on the socket; the **next** call fails, logged with a stale errno | tarantool_client.c:1186-1191 | `kamailio -M 2`, 300–900 kB result, then any call | close the connection (`tnt_conn_fail`) on that path |
| B7 | Medium | Build fails on Ubuntu 20.04 / 24.04 | `Makefile` (pkg-config `msgpack-c` only; fallback `-lmsgpack-c`) | `ld: cannot find -lmsgpack-c` | also try pkg-config `msgpack`, and fall back to `-lmsgpackc` |
| B8 | Low | A bare parameter is coerced to a number | `tnt_pack_json_value`, tarantool_client.c:1024-1043 | `"$ci"` with Call-ID `0123abc@h` → integer `123` | treat input that isn't JSON as one string, or require a JSON array |
| B9 | Low | Non-ASCII `\uXXXX` escapes are dropped | tarantool_client.c:927 | `"\u0416"` → `""` | encode the code point as UTF-8 |
| B10 | Low | A Lua `error()` and "server down" both return -1 | `tnt_exec_call` / `tnt_exec_eval` | `error()` in a procedure | use a separate return code for an application error |
| B11 | Low | `addr` accepts only IPv4 literals | `inet_pton(AF_INET)`, tarantool_client.c:548 | `addr=localhost` / `::1` → `invalid IPv4 address`, and Kamailio exits | use `getaddrinfo` |
| B12 | Low | The 1 MiB response limit is fixed and undocumented | tarantool_client.c:1179 | a 1.1 MB result → rc -1 | make it a modparam, or document it |
| B13 | Info | Non-SIP processes open connections too | `child_init` rank filter | `children=8` → 11 connections | skip ranks that never route |
| B14 | Info | Dead code: `tnt_save_call_sg` / `tnt_get_call_buf` are never called, and feed binary msgpack into the JSON parser | tarantool_client.c:1450-1522 | — | remove them |


Throughput results are in [03-phase2-throughput.md](03-phase2-throughput.md), trunk limits in [04-phase3-trunk-limits.md](04-phase3-trunk-limits.md). The test plan is in [01-test-plan.md](01-test-plan.md). The test configs (Kamailio cfg + SIPp scenarios) are in [rig/](rig/).
