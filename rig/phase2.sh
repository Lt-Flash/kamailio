#!/bin/bash
# Phase 2 quick pass for kamailio#4913: one repeat of S0 (floor) + S1a (5k) + S1b (500k).
# Runs on 223 from /var/tmp/ndbt, unattended. Output: p2/results.tsv (one line per step),
# p2/<arm>/... raw files, p2/DONE when finished. Backends: ndbt-tnt / ndbt-redis (cores 0-1).
# Kamailio: container on cores 4-9. SIPp: cores 10-13.
# Latency: SIPp response times have 1 ms resolution, so p50 on loopback reads ~1.000; the SLO
# (p99 <= 10 ms) and CPU per 1k calls are the comparable numbers.
set -u
set -o pipefail   # a failed correctness gate must stop its arm (gate pipes through tee)
cd /var/tmp/ndbt
IMG=localhost/ndbt-kam:rel
OUT=p2; mkdir -p $OUT
RES=$OUT/results.tsv
STEP_S=${STEP_S:-40}          # seconds per load step
WIN_A=$((STEP_S / 4)); WIN_B=$((STEP_S * 7 / 8))   # CPU window inside a step; SIPp must be alive at both ends
RATES=${RATES:-"1000 2000 5000 10000 20000 30000 40000 60000"}
HZ=$(getconf CLK_TCK)

log() { echo "$(date +%T) $*" | tee -a $OUT/driver.log; }

ticks() {   # sum utime+stime over pids
	local t=0 p
	for p in "$@"; do
		[ -r /proc/$p/stat ] && t=$((t + $(awk '{print $14 + $15}' /proc/$p/stat)))
	done
	echo $t
}
kam_pids() { pgrep -f '^kamailio -f /data/bench.cfg' | tr '\n' ' '; }
be_pid() { podman inspect -f '{{.State.Pid}}' $1 2>/dev/null; }
succ() {   # successful calls so far, from the newest row of a SIPp stat.csv
	python3 -c 'import csv,sys
try:
    r=list(csv.reader(open(sys.argv[1]),delimiter=";")); print(r[-1][r[0].index("SuccessfulCall(C)")])
except Exception: print(0)' "$1"
}

kam_start() {   # arm define(s)
	podman rm -f ndbt-kam-bench >/dev/null 2>&1
	podman run -d --name ndbt-kam-bench --network host --cpuset-cpus=4-9 \
		-v /var/tmp/ndbt:/data:Z $IMG kamailio -f /data/bench.cfg -DD -E $* >/dev/null
	sleep 3
}
kam_stop() { podman logs ndbt-kam-bench > $1/kamailio.log 2>&1; podman rm -f ndbt-kam-bench >/dev/null 2>&1; }

load_data() {   # dir rows   (recreate both backends with that dataset)
	local d=$1
	log "loading dataset $d"
	podman rm -f ndbt-tnt ndbt-redis >/dev/null 2>&1
	rm -rf tdata && mkdir -p tdata && chmod 777 tdata
	podman run -d --name ndbt-tnt --network host --cpuset-cpus=0-1 \
		-v /var/tmp/ndbt:/data:Z -w /data/tdata -e TNT_PORT=13301 -e CDR_TSV=/data/$d/cdr.tsv \
		--entrypoint env docker.io/tarantool/tarantool:3 -u TT_INSTANCE_NAME -u TT_APP_NAME \
		tarantool /data/init.lua >/dev/null
	podman run -d --name ndbt-redis --network host --cpuset-cpus=0-1 docker.io/library/redis:8 \
		redis-server --port 16399 --save "" --appendonly no --io-threads 2 >/dev/null
	sleep 3
	local R="podman exec -i ndbt-redis redis-cli -p 16399"
	$R FUNCTION LOAD REPLACE "$(cat voipbench.lua)" >/dev/null
	$R FT.CREATE idx:cdr ON HASH PREFIX 1 cdr: SCHEMA src TAG ts NUMERIC SORTABLE >/dev/null
	$R --pipe < $d/redis.resp | tail -1 | tee -a $OUT/driver.log
	local n
	for n in $(seq 1 120); do
		[ "$(echo 'box.space.cdr:len()' | podman exec -i ndbt-tnt tt connect kam:kampass@127.0.0.1:13301 -f - 2>/dev/null | grep -Eo '[0-9]+' | head -1)" = "$2" ] && break
		sleep 2
	done
	for n in $(seq 1 120); do
		[ "$($R FT.INFO idx:cdr 2>/dev/null | grep -A1 '^percent_indexed$' | tail -1)" = "1" ] && break
		sleep 2
	done
	log "tarantool rows=$(echo 'box.space.cdr:len()' | podman exec -i ndbt-tnt tt connect kam:kampass@127.0.0.1:13301 -f - 2>/dev/null | grep -Eo '[0-9]+' | head -1) redis keys=$($R DBSIZE) ft docs=$($R FT.INFO idx:cdr | grep -A1 '^num_docs$' | tail -1)"
}

gate() {   # cell arm service mode dir -> 0 if every answer matches
	local cell=$1 arm=$2 svc=$3 mode=$4 d=$5 n=${GATE_N:-200}
	local dir=$OUT/$1-$2
	{ echo SEQUENTIAL; tail -n +2 $d/callers.csv | head -$n; } > $dir/callers_seq.csv
	timeout 600 taskset -c 10-13 sipp 127.0.0.1:5060 -sf cdr_check.xml -s $svc -inf $dir/callers_seq.csv \
		-m $n -r ${GATE_R:-200} -l 50 -i 127.0.0.1 -p 15098 -nostdin -recv_timeout 5000 \
		-trace_logs -log_file $dir/gate.log >/dev/null 2>&1
	python3 - $dir/gate.log $d/expected.tsv $mode $n <<'PY' | tee $dir/gate.txt
import re, sys
log, exp_f, mode, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
exp = dict(l.rstrip("\n").split("\t") for l in open(exp_f))
ok = bad = 0
for l in open(log, errors="replace"):
    m = re.search(r"CHK (\S+) (\S*)", l)
    if not m:
        continue
    want = exp.get(m.group(1), "")
    got = m.group(2)
    if mode == "ids":
        good = got == want or got == '"' + want + '"'
    elif mode == "ft":   # FT.SEARCH NOCONTENT array size = 1 + hits
        good = got == str(1 + len([x for x in want.split(",") if x]))
    else:
        good = got != ""
    ok += good
    bad += not good
print(f"answers={ok + bad}/{n} correct={ok} wrong={bad}")
sys.exit(0 if ok == n else 1)
PY
}

step() {   # cell arm service rate be_container dir -> echoes PASS/FAIL
	local cell=$1 arm=$2 svc=$3 r=$4 be=$5 dir=$OUT/$1-$2/r$4
	mkdir -p $dir
	local m=$((r * STEP_S))
	( cd $dir && exec timeout $((STEP_S + 60)) taskset -c 10-13 sipp 127.0.0.1:5060 \
		-sf /var/tmp/ndbt/cdr_uac.xml -s $svc -inf /var/tmp/ndbt/$DATA/callers.csv \
		-r $r -m $m -l $((r * 2 + 100)) -i 127.0.0.1 -p 15097 -nostdin -recv_timeout 3000 \
		-trace_rtt -rtt_freq 1000 -trace_stat -fd 1 -stf stat.csv >/dev/null 2>&1 ) &
	local sp=$! bp kp k0 b0 k1 b1 alive0 alive1
	bp=$(be_pid $be); kp=$(kam_pids)
	sleep $WIN_A
	kill -0 $sp 2>/dev/null && alive0=1 || alive0=0
	k0=$(ticks $kp); b0=$( [ -n "$bp" ] && ticks $bp || echo 0)
	local c0; c0=$(succ $dir/stat.csv)
	sleep $((WIN_B - WIN_A))
	kill -0 $sp 2>/dev/null && alive1=1 || alive1=0
	k1=$(ticks $kp); b1=$( [ -n "$bp" ] && ticks $bp || echo 0)
	local c1; c1=$(succ $dir/stat.csv)
	wait $sp
	python3 - $dir $cell $arm $r $m $((k1 - k0)) $((b1 - b0)) $HZ $alive0$alive1 $c0 $c1 <<'PY' | tee -a /var/tmp/ndbt/p2/results.tsv
import csv, glob, sys
d, cell, arm, r, m, kt, bt, hz, alive, c0, c1 = sys.argv[1:]
r, m, kt, bt, hz = int(r), int(m), int(kt), int(bt), int(hz)
rows = list(csv.reader(open(f"{d}/stat.csv"), delimiter=";"))
h, last = rows[0], rows[-1]
g = lambda k: int(last[h.index(k)]) if k in h else -1
ok, fail = g("SuccessfulCall(C)"), g("FailedCall(C)")
rt = []
for f in glob.glob(f"{d}/*_rtt.csv"):
    for line in open(f):
        p = line.strip().split(";")
        if len(p) >= 3:
            try:
                rt.append(float(p[2]))
            except ValueError:
                pass
rt.sort()
pc = lambda q: rt[min(len(rt) - 1, int(q * len(rt)))] if rt else float("nan")
calls_win = max(1, int(c1) - int(c0)) if c1.isdigit() and c0.isdigit() and int(c1) > int(c0) else 0
per1k = lambda t: (t / hz * 1000.0) / calls_win * 1000.0 if calls_win else float("nan")
p99 = pc(0.99)
verdict = "PASS" if ok >= 0.95 * m and fail <= 0.001 * m and p99 <= 10.0 and alive == "11" else "FAIL"
print(f"{cell}\t{arm}\t{r}\toffered={m}\tok={ok}\tfail={fail}\tp50={pc(0.5):.3f}\tp99={p99:.3f}"
      f"\tp999={pc(0.999):.3f}\tkam_cpu_ms/1k={per1k(kt):.1f}\tbe_cpu_ms/1k={per1k(bt):.1f}"
      f"\twin_calls={calls_win}\tsipp_alive={alive}\t{verdict}")
PY
}

arm() {   # cell arm define service mode be_container [rates]
	local cell=$1 a=$2 def=$3 svc=$4 mode=$5 be=$6 rates=${7:-$RATES}
	local dir=$OUT/$cell-$a; mkdir -p $dir
	log "arm $cell $a ($def, $svc)"
	kam_start $def
	if [ "$mode" != none ] && ! gate $cell $a $svc $mode $DATA; then
		printf '%s\t%s\tGATE-FAILED\t%s\n' $cell $a "$(cat $dir/gate.txt)" | tee -a $RES
		kam_stop $dir; return
	fi
	# 10 s warm-up at the first rate, not recorded
	( timeout 30 taskset -c 10-13 sipp 127.0.0.1:5060 -sf cdr_uac.xml -s $svc -inf $DATA/callers.csv \
		-r 1000 -m 10000 -i 127.0.0.1 -p 15096 -nostdin -recv_timeout 3000 >/dev/null 2>&1 )
	local r line
	for r in $rates; do
		line=$(step $cell $a $svc $r $be)
		case "$line" in *FAIL) break ;; esac
	done
	kam_stop $dir
}

log "=== phase2 quick pass start; $(podman run --rm $IMG cat /BUILD_REV | head -2 | tr '\n' ' ')"
echo "=== $(date '+%F %T %Z') quick pass, STEP_S=$STEP_S" >> $RES

# ---- 5k dataset (already generated in /var/tmp/ndbt as d5k) ----
DATA=d5k
load_data d5k 5000
if [ -n "${ONLY_S1B:-}" ]; then   # re-run of the S1b arms (500k): ONLY_S1B=1 ./phase2.sh
	DATA=d500k
	load_data d500k 500000
	arm S1b tnt "-A WITH_TNT" cdr ids ndbt-tnt
	GATE_N=20 GATE_R=1 arm S1b redis_scan "-A WITH_REDIS_SCAN" cdr ids ndbt-redis "1 2 5 10"
	DATA=d5k; load_data d5k 5000
	log "=== S1b re-run done"; touch $OUT/DONE; exit 0
fi
if [ -n "${SMOKE:-}" ]; then   # SMOKE=1 STEP_S=15 RATES=1000 ./phase2.sh
	arm S0 none "-A WITH_TNT" none none ndbt-tnt
	arm S1a tnt "-A WITH_TNT" cdr ids ndbt-tnt
	GATE_N=20 arm S1a redis_ft "-A WITH_REDIS_FT" cdr ft ndbt-redis
	log "=== smoke done"; exit 0
fi
arm S0 none   "-A WITH_TNT"       none  none  ndbt-tnt
arm S0 tnt    "-A WITH_TNT"       noop  any   ndbt-tnt
arm S0 redis  "-A WITH_REDIS"     noop  any   ndbt-redis
arm S1a tnt       "-A WITH_TNT"        cdr ids ndbt-tnt
arm S1a redis     "-A WITH_REDIS"      cdr ids ndbt-redis
arm S1a redis_ft  "-A WITH_REDIS_FT"   cdr ft  ndbt-redis
arm S1a redis_scan "-A WITH_REDIS_SCAN" cdr ids ndbt-redis "100 200 500 1000 2000 5000"

# ---- 500k dataset ----
DATA=d500k
load_data d500k 500000
arm S1b tnt       "-A WITH_TNT"        cdr ids ndbt-tnt
arm S1b redis     "-A WITH_REDIS"      cdr ids ndbt-redis
arm S1b redis_ft  "-A WITH_REDIS_FT"   cdr ft  ndbt-redis
GATE_N=20 GATE_R=1 arm S1b redis_scan "-A WITH_REDIS_SCAN" cdr ids ndbt-redis "1 2 5 10"

# leave the 5k dataset loaded, as RESUME.md describes
DATA=d5k
load_data d5k 5000
log "=== phase2 quick pass done"
touch $OUT/DONE
