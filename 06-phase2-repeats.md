# Phase 2 (repeats): throughput through Kamailio, `ndb_tarantool` vs `ndb_redis`

These are three full repeats of the Phase 2 cells. The rig was rebuilt so that it is no longer the limit. The earlier one-repeat pass is in [03-phase2-throughput.md](03-phase2-throughput.md). Run on 2026-10-03, 18:09–20:24 AEST.

## What changed from the quick pass

| | Quick pass | Repeats |
|---|---|---|
| Load generators | 1 SIPp on the Kamailio host | **18 SIPp instances on two other hosts** (12 + 6), ≤ 2,800 cps each even at the 50k step |
| Kamailio | `children=8`, 6 cores | `children=16`, **14 cores** (2–15); the backend stays alone on cores 0–1 |
| UDP buffers | `rmem_default` 212,992 | `rmem`/`wmem` max **and default** 16 MB on all hosts during the run, Kamailio `maxbuffer`/`maxsndbuffer` 16 MB (socket verified `rb16777216`), SIPp `-buff_size` 8 MB |
| Failure attribution | none | every step records drops on Kamailio's UDP 5060 socket and receive-buffer errors on every generator |
| Steps | 1k–20k | 5k, 10k, 15k, 20k, 22.5k, 25k, 27.5k, 30k, 35k, 40k, 50k (40 s each; an arm stops at its first failing step) |
| Repeats | 1 | **3**, arm order rotated per repeat |

The quick pass's "rig ceiling" turned out to be UDP receive-buffer overflow (1.97 M `RcvbufErrors` on the Kamailio host). Its failed calls had no reply at all: `FailedTimeoutOnRecv`, with 0 retransmissions and 0 late or dead-call messages.

With 24 children instead of 16, the highest step passed was the same, at about 7 % more Kamailio CPU per call, so 16 was used.

A step **passes** if ≥ 95 % of calls completed, ≤ 0.1 % failed, p99 ≤ 10 ms, and SIPp was alive for the whole CPU window. Each arm first passed a 200-caller answer-key check in every repeat (the FT arm is checked by hit count).

## Results (3 repeats)

| Arm | Data | Highest step passed (rep 1 / 2 / 3) | Backend CPU per call @ 5k cps | Where the failing step lost calls |
|---|---|---|---|---|
| no backend call | — | **50k / 50k / 50k** (top step) | — | — |
| `ndb_redis` noop (`FCALL`) | — | 27.5k / 35k / 40k | 39–42 µs | Kamailio socket |
| `ndb_tarantool` noop | — | 22.5k / 25k / 27.5k | 48–51 µs | Kamailio socket |
| `ndb_redis` ZSET function | 5k rows | **30k / 30k / 30k** | 49–51 µs | Kamailio socket |
| `ndb_tarantool` TREE index | 5k rows | **20k / 20k / 20k** | 86–90 µs | Kamailio socket |
| `ndb_redis` `FT.SEARCH` | 5k rows | 5k / 5k / 5k | 154–162 µs | Kamailio socket |
| `ndb_redis` ZSET function | 500k rows | **30k / 30k / 30k** | 50–53 µs | Kamailio socket |
| `ndb_tarantool` TREE index | 500k rows | **20k / 15k / 20k** | 88–95 µs | Kamailio socket |
| `ndb_redis` `FT.SEARCH` | 500k rows | 5k / 5k / 5k | 169–172 µs | Kamailio socket |

The generators reported **0** receive-buffer errors across all steps of all repeats. Every failed step lost its calls at Kamailio's socket while its workers were waiting on backend round trips, so the ceilings are backend-bound. At the no-backend ceiling (50k) nothing was dropped anywhere.

## Winner

| Test | Winner | Margin |
|---|---|---|
| Empty call (transport + module) | **`ndb_redis`** | higher step in every repeat (27.5–40k vs 22.5–27.5k), ~20 % less backend CPU per call |
| CDR lookup, per-caller index (ZSET vs TREE), 5k and 500k rows | **`ndb_redis`** | **30k vs 20k cps** in every repeat (15k once for Tarantool at 500k), ~45 % less backend CPU per lookup |
| CDR lookup, general secondary index (`FT.SEARCH` vs TREE) | **`ndb_tarantool`** | 20k vs 5k cps, ~half the backend CPU per lookup |
| Data size 5k → 500k rows | tie | both index designs stay flat |

These results replace the quick pass's "throughput: tie, rig-limited". Once the rig stopped being the limit, `ndb_redis` with a per-caller sorted set sustained about 1.5× the CDR lookup rate of `ndb_tarantool`.

## Rig notes (each one changed a result)

- **ssh:** one ssh session per generator host, not per SIPp instance. sshd's `MaxStartups` (10) randomly refused 12 parallel sessions.
- **Kamailio buffer probe:** it grows from `net.core.rmem_default`, so `rmem_max` alone doesn't help.
- **Restoring sysctls:** a killed driver must still restore them. The trap covers `EXIT`, `TERM` and `INT`.
- **CPU per call:** the "Kamailio µs/call" value at 5k includes idle polling across 16 workers, so compare arms at the same rate, not across rates.

<details>
<summary><b>All data</b>: every step of every arm in every repeat</summary>

| Rep | Cell | Arm | Offered cps | Completed in window (cps) | OK | Failed | p99 ms | Kamailio µs/call | Backend µs/call | Drops at Kamailio :5060 | Generator rcvbuf errors | Verdict |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | S0 | `ndb_tarantool` noop | 5,000 | 5,206 | 199,998 | 0 | 1.000 | 231 | 51 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_tarantool` noop | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 207 | 45 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_tarantool` noop | 15,000 | 15,658 | 599,994 | 0 | 1.000 | 187 | 39 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_tarantool` noop | 20,000 | 20,882 | 799,992 | 0 | 1.000 | 175 | 38 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_tarantool` noop | 22,500 | 23,495 | 900,000 | 0 | 1.000 | 170 | 38 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_tarantool` noop | 25,000 | 25,734 | 994,011 | 5,979 | 1.000 | 166 | 40 | 11,308 | 0 | ❌ |
| 1 | S0 | `ndb_redis` noop | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 229 | 42 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_redis` noop | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 198 | 34 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_redis` noop | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 182 | 31 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_redis` noop | 20,000 | 20,882 | 799,992 | 0 | 1.000 | 174 | 29 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_redis` noop | 22,500 | 23,497 | 900,000 | 0 | 1.000 | 168 | 29 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_redis` noop | 25,000 | 26,093 | 999,990 | 0 | 1.000 | 163 | 29 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_redis` noop | 27,500 | 28,696 | 1,099,998 | 0 | 1.000 | 161 | 28 | 0 | 0 | ✅ |
| 1 | S0 | `ndb_redis` noop | 30,000 | 31,103 | 1,194,751 | 5,237 | 1.000 | 159 | 29 | 9,592 | 0 | ❌ |
| 1 | S0 | no backend call | 5,000 | 5,206 | 199,998 | 0 | 1.000 | 170 | 1 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 10,000 | 10,433 | 399,996 | 0 | 1.000 | 147 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 15,000 | 15,657 | 599,994 | 0 | 1.000 | 138 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 133 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 22,500 | 23,494 | 900,000 | 0 | 1.000 | 129 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 25,000 | 26,088 | 999,990 | 0 | 1.000 | 128 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 27,500 | 28,705 | 1,099,997 | 1 | 1.000 | 128 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 30,000 | 31,315 | 1,199,988 | 0 | 1.000 | 125 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 35,000 | 36,537 | 1,399,986 | 0 | 1.000 | 122 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 40,000 | 41,227 | 1,599,984 | 0 | 1.000 | 121 | 0 | 0 | 0 | ✅ |
| 1 | S0 | no backend call | 50,000 | 51,858 | 1,999,998 | 0 | 1.000 | 114 | 0 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 5,000 | 5,206 | 199,998 | 0 | 1.000 | 230 | 49 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 202 | 45 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 15,000 | 15,661 | 599,994 | 0 | 1.000 | 186 | 42 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 174 | 40 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 22,500 | 23,493 | 900,000 | 0 | 1.000 | 170 | 40 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 25,000 | 26,087 | 999,990 | 0 | 1.000 | 168 | 40 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 27,500 | 28,700 | 1,099,998 | 0 | 1.000 | 165 | 38 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 30,000 | 31,308 | 1,199,988 | 0 | 1.000 | 161 | 39 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` | 35,000 | 35,404 | 1,372,076 | 27,910 | 1.000 | 160 | 38 | 52,930 | 0 | ❌ |
| 1 | S1a | `ndb_redis` `FT.SEARCH` | 5,000 | 5,195 | 199,998 | 0 | 1.000 | 236 | 162 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_redis` `FT.SEARCH` | 10,000 | 10,456 | 395,803 | 4,193 | 1.000 | 190 | 146 | 7,701 | 0 | ❌ |
| 1 | S1a | `ndb_tarantool` | 5,000 | 5,173 | 199,998 | 0 | 1.000 | 235 | 86 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_tarantool` | 10,000 | 10,433 | 399,996 | 0 | 1.000 | 206 | 75 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_tarantool` | 15,000 | 15,660 | 599,994 | 0 | 1.000 | 187 | 69 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_tarantool` | 20,000 | 20,908 | 799,992 | 0 | 1.000 | 175 | 67 | 0 | 0 | ✅ |
| 1 | S1a | `ndb_tarantool` | 22,500 | 22,937 | 884,962 | 15,038 | 1.000 | 176 | 69 | 25,958 | 0 | ❌ |
| 1 | S1b | `ndb_redis` | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 228 | 51 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 206 | 48 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 182 | 42 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` | 20,000 | 20,884 | 799,992 | 0 | 1.000 | 173 | 41 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` | 22,500 | 23,493 | 900,000 | 0 | 1.000 | 168 | 41 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` | 25,000 | 26,087 | 999,990 | 0 | 1.000 | 165 | 40 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` | 27,500 | 28,700 | 1,099,998 | 0 | 1.000 | 161 | 41 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` | 30,000 | 31,338 | 1,199,988 | 0 | 1.000 | 159 | 40 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` | 35,000 | 35,767 | 1,379,513 | 20,473 | 1.000 | 155 | 39 | 38,942 | 0 | ❌ |
| 1 | S1b | `ndb_redis` `FT.SEARCH` | 5,000 | 5,207 | 199,998 | 0 | 1.000 | 238 | 170 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_redis` `FT.SEARCH` | 10,000 | 9,760 | 375,031 | 24,965 | 1.000 | 192 | 157 | 46,324 | 0 | ❌ |
| 1 | S1b | `ndb_tarantool` | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 240 | 92 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_tarantool` | 10,000 | 10,433 | 399,996 | 0 | 1.000 | 204 | 78 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_tarantool` | 15,000 | 15,658 | 599,994 | 0 | 1.000 | 186 | 75 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_tarantool` | 20,000 | 20,841 | 799,992 | 0 | 1.000 | 175 | 73 | 0 | 0 | ✅ |
| 1 | S1b | `ndb_tarantool` | 22,500 | 20,849 | 813,669 | 86,331 | 1.000 | 177 | 76 | 152,516 | 0 | ❌ |
| 2 | S0 | `ndb_redis` noop | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 223 | 39 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 197 | 33 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 181 | 31 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 167 | 28 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 22,500 | 23,494 | 900,000 | 0 | 1.000 | 165 | 27 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 25,000 | 26,091 | 999,990 | 0 | 1.000 | 164 | 28 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 27,500 | 28,699 | 1,099,998 | 0 | 1.000 | 161 | 26 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 30,000 | 31,312 | 1,199,988 | 0 | 1.000 | 156 | 27 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 35,000 | 36,520 | 1,399,986 | 0 | 1.000 | 153 | 29 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_redis` noop | 40,000 | 37,217 | 1,471,808 | 128,176 | 1.000 | 150 | 31 | 236,495 | 0 | ❌ |
| 2 | S0 | no backend call | 5,000 | 5,162 | 199,998 | 0 | 1.000 | 168 | 1 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 149 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 139 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 133 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 22,500 | 23,494 | 900,000 | 0 | 1.000 | 130 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 25,000 | 26,089 | 999,990 | 0 | 1.000 | 130 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 27,500 | 28,700 | 1,099,998 | 0 | 1.000 | 130 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 30,000 | 31,312 | 1,199,988 | 0 | 1.000 | 128 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 35,000 | 36,537 | 1,399,986 | 0 | 1.000 | 125 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 40,000 | 41,762 | 1,599,958 | 26 | 1.000 | 121 | 0 | 0 | 0 | ✅ |
| 2 | S0 | no backend call | 50,000 | 52,191 | 1,999,998 | 0 | 1.000 | 120 | 0 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_tarantool` noop | 5,000 | 5,140 | 199,998 | 0 | 1.000 | 231 | 48 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_tarantool` noop | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 202 | 42 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_tarantool` noop | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 190 | 41 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_tarantool` noop | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 177 | 39 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_tarantool` noop | 22,500 | 23,493 | 900,000 | 0 | 1.000 | 172 | 38 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_tarantool` noop | 25,000 | 26,088 | 999,990 | 0 | 1.000 | 167 | 41 | 0 | 0 | ✅ |
| 2 | S0 | `ndb_tarantool` noop | 27,500 | 28,027 | 1,092,161 | 7,837 | 1.000 | 166 | 41 | 14,689 | 0 | ❌ |
| 2 | S1a | `ndb_redis` `FT.SEARCH` | 5,000 | 5,207 | 199,998 | 0 | 1.000 | 244 | 161 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` `FT.SEARCH` | 10,000 | 10,254 | 396,825 | 3,171 | 1.000 | 196 | 149 | 5,818 | 0 | ❌ |
| 2 | S1a | `ndb_tarantool` | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 238 | 87 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_tarantool` | 10,000 | 10,432 | 399,996 | 0 | 1.000 | 208 | 74 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_tarantool` | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 188 | 69 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_tarantool` | 20,000 | 20,885 | 799,992 | 0 | 1.000 | 177 | 67 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_tarantool` | 22,500 | 23,414 | 898,180 | 1,820 | 1.000 | 171 | 66 | 3,433 | 0 | ❌ |
| 2 | S1a | `ndb_redis` | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 227 | 51 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 201 | 44 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 182 | 41 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` | 20,000 | 20,883 | 799,992 | 0 | 1.000 | 172 | 40 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` | 22,500 | 23,494 | 900,000 | 0 | 1.000 | 169 | 39 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` | 25,000 | 26,088 | 999,990 | 0 | 1.000 | 165 | 39 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` | 27,500 | 28,700 | 1,099,998 | 0 | 1.000 | 162 | 38 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` | 30,000 | 31,310 | 1,199,988 | 0 | 1.000 | 160 | 38 | 0 | 0 | ✅ |
| 2 | S1a | `ndb_redis` | 35,000 | 36,302 | 1,370,953 | 29,033 | 1.000 | 156 | 38 | 54,354 | 0 | ❌ |
| 2 | S1b | `ndb_redis` `FT.SEARCH` | 5,000 | 5,208 | 199,998 | 0 | 1.000 | 239 | 172 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` `FT.SEARCH` | 10,000 | 9,959 | 386,089 | 13,907 | 1.000 | 191 | 153 | 27,072 | 0 | ❌ |
| 2 | S1b | `ndb_tarantool` | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 237 | 88 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_tarantool` | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 205 | 76 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_tarantool` | 15,000 | 15,653 | 599,994 | 0 | 1.000 | 185 | 71 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_tarantool` | 20,000 | 21,012 | 796,648 | 3,344 | 1.000 | 175 | 70 | 5,823 | 0 | ❌ |
| 2 | S1b | `ndb_redis` | 5,000 | 5,140 | 199,998 | 0 | 1.000 | 223 | 50 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 197 | 44 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 181 | 42 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 168 | 41 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` | 22,500 | 23,493 | 900,000 | 0 | 1.000 | 166 | 41 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` | 25,000 | 26,091 | 999,990 | 0 | 1.000 | 165 | 40 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` | 27,500 | 28,699 | 1,099,998 | 0 | 1.000 | 162 | 40 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` | 30,000 | 31,312 | 1,199,988 | 0 | 1.000 | 158 | 39 | 0 | 0 | ✅ |
| 2 | S1b | `ndb_redis` | 35,000 | 35,176 | 1,354,057 | 45,929 | 1.000 | 155 | 39 | 85,824 | 0 | ❌ |
| 3 | S0 | no backend call | 5,000 | 5,206 | 199,998 | 0 | 1.000 | 163 | 1 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 146 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 15,000 | 15,657 | 599,994 | 0 | 1.000 | 136 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 135 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 22,500 | 23,494 | 900,000 | 0 | 1.000 | 130 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 25,000 | 26,088 | 999,990 | 0 | 1.000 | 130 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 27,500 | 28,699 | 1,099,998 | 0 | 1.000 | 130 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 30,000 | 31,312 | 1,199,988 | 0 | 1.000 | 126 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 35,000 | 36,545 | 1,399,959 | 27 | 1.000 | 121 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 40,000 | 41,227 | 1,599,896 | 88 | 1.000 | 122 | 0 | 0 | 0 | ✅ |
| 3 | S0 | no backend call | 50,000 | 52,192 | 1,999,998 | 0 | 1.000 | 117 | 0 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_tarantool` noop | 5,000 | 5,151 | 199,998 | 0 | 1.000 | 222 | 48 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_tarantool` noop | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 201 | 43 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_tarantool` noop | 15,000 | 15,657 | 599,994 | 0 | 1.000 | 182 | 41 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_tarantool` noop | 20,000 | 20,880 | 799,992 | 0 | 1.000 | 174 | 42 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_tarantool` noop | 22,500 | 23,494 | 900,000 | 0 | 1.000 | 168 | 43 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_tarantool` noop | 25,000 | 26,067 | 999,990 | 0 | 1.000 | 165 | 39 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_tarantool` noop | 27,500 | 28,702 | 1,099,998 | 0 | 1.000 | 162 | 37 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_tarantool` noop | 30,000 | 30,227 | 1,172,856 | 27,132 | 1.000 | 159 | 40 | 47,727 | 0 | ❌ |
| 3 | S0 | `ndb_redis` noop | 5,000 | 5,140 | 199,998 | 0 | 1.000 | 220 | 40 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 10,000 | 10,434 | 399,996 | 0 | 1.000 | 196 | 33 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 183 | 31 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 171 | 29 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 22,500 | 23,493 | 900,000 | 0 | 1.000 | 166 | 29 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 25,000 | 26,088 | 999,990 | 0 | 1.000 | 162 | 28 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 27,500 | 28,706 | 1,099,998 | 0 | 1.000 | 158 | 29 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 30,000 | 31,313 | 1,199,988 | 0 | 1.000 | 158 | 27 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 35,000 | 36,549 | 1,399,986 | 0 | 1.000 | 153 | 26 | 0 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 40,000 | 41,716 | 1,598,831 | 1,153 | 1.000 | 150 | 26 | 2,283 | 0 | ✅ |
| 3 | S0 | `ndb_redis` noop | 50,000 | 42,448 | 1,633,413 | 366,585 | 1.000 | 144 | 28 | 656,729 | 0 | ❌ |
| 3 | S1a | `ndb_tarantool` | 5,000 | 5,162 | 199,998 | 0 | 1.000 | 234 | 90 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_tarantool` | 10,000 | 10,433 | 399,996 | 0 | 1.000 | 204 | 73 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_tarantool` | 15,000 | 15,659 | 599,994 | 0 | 1.000 | 185 | 72 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_tarantool` | 20,000 | 20,888 | 799,992 | 0 | 1.000 | 175 | 68 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_tarantool` | 22,500 | 22,533 | 878,712 | 21,288 | 1.000 | 172 | 70 | 38,488 | 0 | ❌ |
| 3 | S1a | `ndb_redis` | 5,000 | 5,150 | 199,998 | 0 | 1.000 | 226 | 51 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 198 | 44 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` | 15,000 | 15,660 | 599,994 | 0 | 1.000 | 181 | 40 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` | 20,000 | 20,881 | 799,992 | 0 | 1.000 | 172 | 40 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` | 22,500 | 23,493 | 900,000 | 0 | 1.000 | 166 | 39 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` | 25,000 | 26,088 | 999,990 | 0 | 1.000 | 161 | 39 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` | 27,500 | 28,700 | 1,099,998 | 0 | 1.000 | 160 | 38 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` | 30,000 | 31,311 | 1,199,988 | 0 | 1.000 | 158 | 39 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` | 35,000 | 36,563 | 1,394,450 | 5,536 | 1.000 | 151 | 37 | 10,083 | 0 | ❌ |
| 3 | S1a | `ndb_redis` `FT.SEARCH` | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 240 | 154 | 0 | 0 | ✅ |
| 3 | S1a | `ndb_redis` `FT.SEARCH` | 10,000 | 10,025 | 391,813 | 8,183 | 1.000 | 192 | 150 | 15,134 | 0 | ❌ |
| 3 | S1b | `ndb_tarantool` | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 237 | 95 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_tarantool` | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 204 | 77 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_tarantool` | 15,000 | 15,662 | 599,994 | 0 | 1.000 | 184 | 70 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_tarantool` | 20,000 | 20,873 | 799,992 | 0 | 1.000 | 173 | 66 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_tarantool` | 22,500 | 23,159 | 883,056 | 16,944 | 1.000 | 169 | 68 | 31,694 | 0 | ❌ |
| 3 | S1b | `ndb_redis` | 5,000 | 5,139 | 199,998 | 0 | 1.000 | 228 | 53 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` | 10,000 | 10,431 | 399,996 | 0 | 1.000 | 201 | 48 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` | 15,000 | 15,656 | 599,994 | 0 | 1.000 | 184 | 43 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` | 20,000 | 20,882 | 799,992 | 0 | 1.000 | 170 | 41 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` | 22,500 | 23,494 | 900,000 | 0 | 1.000 | 168 | 41 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` | 25,000 | 26,087 | 999,990 | 0 | 1.000 | 166 | 40 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` | 27,500 | 28,700 | 1,099,998 | 0 | 1.000 | 163 | 40 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` | 30,000 | 31,312 | 1,199,988 | 0 | 1.000 | 157 | 40 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` | 35,000 | 34,182 | 1,326,179 | 73,807 | 1.000 | 154 | 40 | 139,930 | 0 | ❌ |
| 3 | S1b | `ndb_redis` `FT.SEARCH` | 5,000 | 5,207 | 199,998 | 0 | 1.000 | 240 | 169 | 0 | 0 | ✅ |
| 3 | S1b | `ndb_redis` `FT.SEARCH` | 10,000 | 9,941 | 382,953 | 17,043 | 1.000 | 190 | 155 | 32,410 | 0 | ❌ |

"Completed in window" is the successful calls counted between 10 s and 35 s into each 40 s step, divided by 25 s. CPU per call is utime+stime over the same window divided by the calls completed in it. The raw data is in [results/phase2r/](results/phase2r/).
</details>
