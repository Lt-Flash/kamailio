#!/usr/bin/env python3
"""Generate ONE deterministic CDR set and emit it for both backends.

  gen_cdr.py N CALLERS OUTDIR [seed]

Writes:
  OUTDIR/cdr.tsv        id src dst ts dur      -> Tarantool (CDR_TSV=... / cdr_load_tsv)
  OUTDIR/redis.resp     RESP stream            -> redis-cli --pipe < redis.resp
                        HSET cdr:<id> (for the Query Engine arm)
                        ZADD cdr:src:<src> ts id (fair arm)
                        RPUSH cdrs:all <json>  (strawman arm)
  OUTDIR/expected.tsv   src -> newest 20 ids   (answer key: every arm must match it)
  OUTDIR/callers.csv    SIPp injection file (one caller per line)

NO_SCAN=1 skips the cdrs:all strawman list (use at 2M rows: 223 has 3 GB RAM).
"""
import json
import os
import random
import sys
from collections import defaultdict

n, callers, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
rnd = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 4913)
srcs = ["61%08d" % (1000 + i) for i in range(callers)]


def resp(*args):
    parts = ["*%d\r\n" % len(args)]
    for a in args:
        b = str(a)
        parts.append("$%d\r\n%s\r\n" % (len(b.encode()), b))
    return "".join(parts)


by_src = defaultdict(list)
ts = 1_790_000_000
with open(f"{out}/cdr.tsv", "w") as tsv, open(f"{out}/redis.resp", "w") as rp:
    for i in range(1, n + 1):
        ts += rnd.randint(1, 3)  # strictly increasing: no ts ties, so order is unambiguous
        src = rnd.choice(srcs)
        dst = "61%09d" % rnd.randint(0, 999_999_999)
        dur = rnd.randint(0, 3600)
        tsv.write(f"{i}\t{src}\t{dst}\t{ts}\t{dur}\n")
        rp.write(resp("HSET", f"cdr:{i}", "src", src, "dst", dst, "ts", ts, "dur", dur))
        rp.write(resp("ZADD", f"cdr:src:{src}", ts, i))
        if not os.environ.get("NO_SCAN"):
            rp.write(resp("RPUSH", "cdrs:all",
                          json.dumps({"id": i, "src": src, "dst": dst, "ts": ts, "dur": dur})))
        by_src[src].append((ts, i))

with open(f"{out}/expected.tsv", "w") as ex:
    for src in srcs:
        rows = sorted(by_src[src], reverse=True)[:20]
        ex.write(src + "\t" + ",".join(str(r[1]) for r in rows) + "\n")

with open(f"{out}/callers.csv", "w") as cf:
    cf.write("RANDOM\n")
    for s in srcs:
        cf.write(s + "\n")
