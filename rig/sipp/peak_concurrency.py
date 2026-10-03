#!/usr/bin/env python3
"""peak_concurrency.py LIMIT trunk_uas_logs...  -> true peak simultaneous calls.
Exit 1 if the peak exceeds LIMIT. Ties: DOWN sorts before UP (a slot freed and
re-used in the same millisecond is not an overlap)."""
import re
import sys

limit, ev = int(sys.argv[1]), []
for path in sys.argv[2:]:
    for line in open(path, errors="replace"):
        m = re.search(r"\b(UP|DOWN) (\d+) (\S+)", line)
        if m:
            ev.append((int(m.group(2)), 0 if m.group(1) == "DOWN" else 1))
ev.sort()
cur = peak = ups = 0
for _, kind in ev:
    cur += 1 if kind else -1
    ups += kind
    peak = max(peak, cur)
print(f"calls={ups} peak={peak} limit={limit} open_at_end={cur}")
sys.exit(1 if peak > limit else 0)
