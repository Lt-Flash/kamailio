#!/bin/bash
# Phase 3 for kamailio#4913: trunk channel limits (15 / 35 / 50) under a burst of concurrent INVITEs.
# Runs on 223 from /var/tmp/ndbt.   RUNS=20 ./phase3.sh [arm...]
#   arms: tnt redis naive yield   (default: all four)
# VARIANT (lifecycle, Phase 3a-c):
#   base  plain run (default)
#   3a    trunk UAS reject ~10 % of INVITEs with 486 -> failure_route must release
#   3b    backend stalled STALL_S=3 s (> cmd_timeout 1 s) while the burst arrives -> leaked reservations?
#   3c    kill -9 Kamailio 1 s into the hold, restart at once; BYEs arrive at the new instance
#   3cx   kill -9 Kamailio 1 s into the hold, restart only after the BYEs have given up (~40 s)
# Each run: reset counters, start 3 trunk UAS (5071-5073), burst N calls within BURST_MS,
# hold HOLD_MS, BYE. Ground truth = peak simultaneous answered calls per trunk (UAS logs).
# Output: p3/results.tsv (one line per run), p3/<arm>/run<k>/..., p3/DONE.
set -u
set -o pipefail
cd /var/tmp/ndbt
IMG=localhost/ndbt-kam:rel
OUT=${OUT:-p3}; mkdir -p $OUT
RES=$OUT/results.tsv
RUNS=${RUNS:-20}
CALLS=${CALLS:-120}
BURST_MS=${BURST_MS:-20}
HOLD_MS=${HOLD_MS:-5000}
ARMS=${*:-tnt redis naive yield}
VARIANT=${VARIANT:-base}
UAS_XML=trunk_uas.xml; [ "$VARIANT" = 3a ] && UAS_XML=trunk_uas_486.xml
CUR_DEF=""
LIM=(0 15 35 50)

log() { echo "$(date +%T) $*" | tee -a $OUT/driver.log; }
tnt() { echo "$1" | podman exec -i ndbt-tnt tt connect kam:kampass@127.0.0.1:13301 -f - 2>/dev/null; }
R="podman exec -i ndbt-redis redis-cli -p 16399"

reset() {
	tnt "trunks_set(15,35,50)" >/dev/null
	$R DEL resv trunk:1:calls trunk:2:calls trunk:3:calls >/dev/null
}
inuse() {   # backend's own view after the run: "t1 t2 t3"
	case $1 in
	tnt|yield) tnt "lcr_inuse()" | grep -Eo '[0-9]+' | tr '\n' ' ' ;;
	*) echo "$($R SCARD trunk:1:calls) $($R SCARD trunk:2:calls) $($R SCARD trunk:3:calls)" ;;
	esac
}

STALL_S=${STALL_S:-3}
stall() {   # arm: block the backend's main thread for STALL_S s (one atomic busy loop)
	case $1 in
	tnt|yield) tnt "require('fiber').self():set_max_slice(10) local c=require('clock') local t=c.monotonic() while c.monotonic()-t < $STALL_S do end return 'stalled'" >/dev/null ;;
	*) $R EVAL "local s=redis.call('TIME') local a=tonumber(s[1])+tonumber(s[2])/1e6 while true do local n=redis.call('TIME') if tonumber(n[1])+tonumber(n[2])/1e6-a > tonumber(ARGV[1]) then break end end return 1" 0 $STALL_S >/dev/null ;;
	esac
}

kam_start() {
	CUR_DEF="$*"
	podman rm -f ndbt-kam-lcr >/dev/null 2>&1
	podman run -d --name ndbt-kam-lcr --network host --cpuset-cpus=4-9 \
		-v /var/tmp/ndbt:/data:Z $IMG kamailio -f /data/bench.cfg -DD -E $* >/dev/null
	sleep 3
}
kam_stop() { podman logs ndbt-kam-lcr > $1/kamailio.log 2>&1; podman rm -f ndbt-kam-lcr >/dev/null 2>&1; }

one_run() {   # arm k
	local arm=$1 k=$2 d=$OUT/$1/run$2 t pids=()
	mkdir -p $d
	reset
	for t in 1 2 3; do
		taskset -c 12-13 sipp -sf $UAS_XML -i 127.0.0.1 -p $((5070 + t)) -nostdin \
			-trace_logs -log_file $d/uas$t.log >/dev/null 2>&1 &
		pids+=($!)
	done
	sleep 1
	local hook=""
	case $VARIANT in
	3b)  ( s0=$(date +%s%N); stall $arm; echo "stall ${STALL_S}s ran $(( ($(date +%s%N) - s0) / 1000000 )) ms incl. podman exec" > $d/hook.txt ) & hook=$!
	     sleep 0.8 ;;   # podman exec needs ~0.3-0.5 s before the stall is live
	3c)  ( sleep 1; podman kill -s KILL ndbt-kam-lcr >/dev/null 2>&1; kam_start $CUR_DEF; echo "killed+restarted $(date +%T.%N | cut -c1-12)" > $d/hook.txt ) & hook=$! ;;
	3cx) ( sleep 1; podman kill -s KILL ndbt-kam-lcr >/dev/null 2>&1; sleep 40; kam_start $CUR_DEF; echo "killed, restarted after 40 s" > $d/hook.txt ) & hook=$! ;;
	esac
	timeout $(((HOLD_MS / 1000) + 90)) taskset -c 10-11 sipp 127.0.0.1:5060 -sf lcr_uac.xml -s lcr \
		-m $CALLS -l $CALLS -r $CALLS -rp $BURST_MS -d $HOLD_MS -i 127.0.0.1 -p 15095 -nostdin \
		-recv_timeout 10000 -trace_logs -log_file $d/uac.log -trace_stat -fd 1 -stf $d/uac_stat.csv \
		>/dev/null 2>&1
	local uac_rc=$?
	[ -n "$hook" ] && wait $hook 2>/dev/null
	sleep 2
	local left; left=$(inuse $arm)
	for t in 0 1 2; do kill ${pids[$t]} 2>/dev/null; done
	wait "${pids[@]}" 2>/dev/null
	local full; full=$(grep -c 'FULL ' $d/uac.log 2>/dev/null)
	local rej; rej=$(grep -c 'REJ486 ' $d/uac.log 2>/dev/null)
	local line="$arm	run$k" viol=0
	for t in 1 2 3; do
		local pk; pk=$(python3 peak_concurrency.py ${LIM[$t]} $d/uas$t.log)
		[ $? -ne 0 ] && viol=1
		line="$line	t$t:$(echo "$pk" | sed 's/calls=\([0-9]*\) peak=\([0-9]*\) limit=\([0-9]*\) open_at_end=\([0-9]*\)/calls=\1 peak=\2\/\3 open=\4/')"
	done
	local ok fail
	ok=$(python3 -c 'import csv,sys
r=list(csv.reader(open(sys.argv[1]),delimiter=";")); h=r[0]; print(r[-1][h.index("SuccessfulCall(C)")], r[-1][h.index("FailedCall(C)")])' $d/uac_stat.csv 2>/dev/null || echo "? ?")
	local up; up=$(cat $d/uas*.log 2>/dev/null | grep -c 'UP ')
	printf '%s\tanswered=%s\t503=%s\t486=%s\tuac_ok/fail=%s\tleft_in_backend=%s\tuac_rc=%s\t%s\n' "$line" "$up" "$full" "$rej" "$ok" "$left" $uac_rc \
		"$([ $viol = 1 ] && echo OVERSOLD || echo within-limits)" | tee -a $RES
}

declare -A DEF=([tnt]="-A WITH_TNT" [redis]="-A WITH_REDIS" [naive]="-A WITH_REDIS_NAIVE" [yield]="-A WITH_TNT -A TNT_YIELD")
log "=== phase3 start: arms=$ARMS runs=$RUNS calls=$CALLS burst=${BURST_MS}ms hold=${HOLD_MS}ms; $(podman run --rm $IMG cat /BUILD_REV | head -2 | tr '\n' ' ')"
echo "=== $(date '+%F %T %Z') variant=$VARIANT runs=$RUNS calls=$CALLS burst=${BURST_MS}ms hold=${HOLD_MS}ms limits=15/35/50" >> $RES
for arm in $ARMS; do
	log "arm $arm (${DEF[$arm]})"
	mkdir -p $OUT/$arm
	kam_start ${DEF[$arm]}
	for k in $(seq 1 $RUNS); do one_run $arm $k; done
	kam_stop $OUT/$arm
done
log "=== phase3 done"
touch $OUT/DONE
