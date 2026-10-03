#!/bin/bash
# Phase 1 probes for kamailio#4913 (ndb_tarantool). Runs on 223 from /var/tmp/ndbt.
#   ./phase1.sh [stage...]      stages: basic slow big addr conns restart vers   (default: all)
# Needs: ndbt-tnt (Tarantool 3, :13301) running, image localhost/ndbt-kam:rel, sipp on host.
# Output: p1/<stage>/... and one line per probe in p1/results.txt
set -u
cd /var/tmp/ndbt
IMG=${IMG:-localhost/ndbt-kam:rel}
KAM_OPTS=${KAM_OPTS:-}   # extra podman run options, e.g. sanitizer env + ptrace for LSan
OUT=${OUT:-p1}
mkdir -p $OUT
RES=$OUT/results.txt
STAGES=${*:-basic slow big addr conns restart vers}

kam_start() {   # name cfg [extra kamailio args...]
	local name=$1 cfg=$2; shift 2
	podman rm -f "$name" >/dev/null 2>&1
	podman run -d --name "$name" --network host -v /var/tmp/ndbt:/data:Z $KAM_OPTS $IMG \
		kamailio -f "/data/$cfg" -DD -E "$@" >/dev/null
	sleep 2
}
kam_stop() { podman stop -t 20 "$1" >/dev/null 2>&1; podman rm -f "$1" >/dev/null 2>&1; }   # SIGTERM first: LSan reports at exit

probe() {   # stage name cid
	local st=$1 name=$2 cid=$3 t0 t1 line
	mkdir -p $OUT/$st
	rm -f $OUT/$st/$name.log
	t0=$(date +%s%N)
	timeout 30 sipp 127.0.0.1:5060 -sf probe.xml -s "$name" -cid_str "$cid" -m 1 \
		-i 127.0.0.1 -p 15099 -nostdin -trace_logs -log_file $OUT/$st/$name.log >/dev/null 2>&1
	t1=$(date +%s%N)
	line=$(grep -h "cid=" $OUT/$st/$name.log 2>/dev/null | tail -1 | sed 's/^[^:]*: //' | cut -c1-300)
	printf '%s\t%s\t%dms\t%s\n' "$st" "$name" $(((t1 - t0) / 1000000)) "${line:-NO REPLY}" | tee -a $RES
}

klog() { podman logs --timestamps "$1" 2>&1; }

echo "=== phase1 $(date '+%F %T %Z') stages: $STAGES" | tee -a $RES
podman run --rm $IMG cat /BUILD_REV | head -2 | tee -a $RES

for st in $STAGES; do case $st in

basic)  # P1-P4, P8
	kam_start ndbt-kam-faults faults.cfg
	probe basic p_types   '0123abc@h'
	probe basic p_inject  'x","injected'
	probe basic p_unicode 'u1@h'
	probe basic p_badjson 'b1@h'
	probe basic p_after   'b2@h'
	probe basic p_badjson2 'b3@h'
	probe basic p_after   'b4@h'
	probe basic p_err     'e1@h'
	probe basic p_nil     'e2@h'
	probe basic p_multi   'e3@h'
	klog ndbt-kam-faults > $OUT/basic/kamailio.log
	kam_stop ndbt-kam-faults
	;;

slow)   # P5 timeouts on a live server, P6 connect refused (control)
	kam_start ndbt-kam-faults faults.cfg
	for i in 1 2 3 4 5 6; do probe slow p_slow "s$i@h"; done
	probe slow p_short_ok 'sok@h'
	for i in 1 2 3 4 5; do probe slow p_dead "d$i@h"; done
	klog ndbt-kam-faults > $OUT/slow/kamailio.log
	{
		echo "slow	marked-disabled(short:13301)	$(grep -c '13301 marked disabled' $OUT/slow/kamailio.log)"
		echo "slow	recv-failures(short:13301)	$(grep -c 'failed to receive IPROTO_CALL response header from 127.0.0.1:13301' $OUT/slow/kamailio.log)"
		echo "slow	marked-disabled(dead:13399)	$(grep -c '13399 marked disabled' $OUT/slow/kamailio.log)"
		echo "slow	connect-attempts(dead:13399)	$(grep -c 'connect() to 127.0.0.1:13399 failed' $OUT/slow/kamailio.log)"
	} | tee -a $RES
	kam_stop ndbt-kam-faults
	;;

big)    # P7 / P7b: default pkg (8 MB) first as the baseline, then -M 2
	for m in 8 2; do
		kam_start ndbt-kam-faults faults.cfg -M $m
		probe big-M$m p_big    "g1@h"
		probe big-M$m p_seq_a  "g2@h"
		probe big-M$m p_seq_b  "g3@h"
		probe big-M$m p_huge   "g4@h"
		probe big-M$m p_seq_a  "g5@h"
		probe big-M$m p_seq_b  "g6@h"
		klog ndbt-kam-faults > $OUT/big-M$m/kamailio.log
		kam_stop ndbt-kam-faults
	done
	;;

addr)   # P9: hostnames / IPv6, init_without_tarantool off
	mkdir -p $OUT/addr
	for a in 127.0.0.1 localhost ::1; do
		f=addr_$(echo $a | tr -c 'a-z0-9\n' '_').cfg
		sed -e '/name=short;/d; /name=dead;/d; /init_without_tarantool/d' \
			-e "s/name=default;addr=127.0.0.1;/name=default;addr=$a;/" faults.cfg > $f
		kam_start ndbt-kam-addr $f
		sleep 2
		st=$(podman inspect -f '{{.State.Status}}' ndbt-kam-addr 2>/dev/null)
		klog ndbt-kam-addr > $OUT/addr/$f.log
		printf 'addr\t%s\tcontainer=%s\t%s\n' "$a" "$st" \
			"$(grep -m1 -E 'invalid IPv4|failed to connect|ERROR' $OUT/addr/$f.log | cut -c1-200)" | tee -a $RES
		kam_stop ndbt-kam-addr
	done
	;;

conns)  # P10: connections per process with the bench config (children=8)
	mkdir -p $OUT/conns
	kam_start ndbt-kam-bench bench.cfg -A WITH_TNT
	sleep 2
	np=$(podman top ndbt-kam-bench comm 2>/dev/null | grep -c kamailio)
	nc=$(ss -Htn state established '( dport = :13301 )' | wc -l)
	podman top ndbt-kam-bench pid args > $OUT/conns/procs.txt 2>&1
	printf 'conns\tkamailio-processes=%s\testablished-to-13301=%s\n' "$np" "$nc" | tee -a $RES
	kam_stop ndbt-kam-bench
	;;

restart) # P11: Tarantool restart under 1k cps of cdr; every answer checked
	mkdir -p $OUT/restart
	{ echo SEQUENTIAL; tail -n +2 callers.csv; } > callers_seq.csv
	kam_start ndbt-kam-bench bench.cfg -A WITH_TNT
	timeout 60 sipp 127.0.0.1:5060 -sf cdr_check.xml -s cdr -inf callers_seq.csv -m 200 -r 200 \
		-i 127.0.0.1 -p 15098 -nostdin -trace_logs -log_file $OUT/restart/before.log >/dev/null 2>&1
	timeout 90 sipp 127.0.0.1:5060 -sf cdr_check.xml -s cdr -inf callers.csv -m 20000 -r 1000 \
		-i 127.0.0.1 -p 15097 -nostdin -trace_logs -log_file $OUT/restart/load.log \
		-trace_stat -stf $OUT/restart/load_stat.csv >/dev/null 2>&1 &
	L=$!
	sleep 5
	podman restart ndbt-tnt >/dev/null
	echo "tarantool restarted at $(date +%T)" > $OUT/restart/when.txt
	wait $L
	timeout 60 sipp 127.0.0.1:5060 -sf cdr_check.xml -s cdr -inf callers_seq.csv -m 200 -r 200 \
		-i 127.0.0.1 -p 15098 -nostdin -trace_logs -log_file $OUT/restart/after.log >/dev/null 2>&1
	klog ndbt-kam-bench > $OUT/restart/kamailio.log
	kam_stop ndbt-kam-bench
	for f in before load after; do
		python3 - "$OUT/restart/$f.log" expected.tsv <<'PY' | sed "s/^/restart\t$f\t/" | tee -a $RES
import re, sys
exp = dict(l.rstrip("\n").split("\t") for l in open(sys.argv[2]))
ok = bad = 0
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"CHK (\S+) (\S*)", l)
    if not m:
        continue
    if exp.get(m.group(1)) == m.group(2):
        ok += 1
    else:
        bad += 1
        if bad <= 3:
            print("WRONG", m.group(1), m.group(2)[:60])
print(f"answers={ok + bad} correct={ok} wrong={bad}")
PY
	done
	printf 'restart\tkamailio-errors=%s\n' "$(grep -c ERROR $OUT/restart/kamailio.log)" | tee -a $RES
	printf 'restart\ttarantool-ready-again=%s\n' "$(podman logs --timestamps ndbt-tnt 2>&1 | grep 'ready to accept' | tail -1 | cut -c12-23)" | tee -a $RES
	printf 'restart\tfirst-failure=%s last-failure=%s disabled-marks=%s\n' \
		"$(grep -E 'is down|failed to' $OUT/restart/kamailio.log | head -1 | cut -c12-23)" \
		"$(grep -E 'is down|failed to' $OUT/restart/kamailio.log | tail -1 | cut -c12-23)" \
		"$(grep -c 'marked disabled' $OUT/restart/kamailio.log)" | tee -a $RES
	;;
vers)   # P12: Tarantool 2.11 and 1.10 on :13302 (one at a time), core probes
	sed 's/port=13301;/port=13302;/g' faults.cfg > faults_13302.cfg
	sed 's/pass=kampass/pass=WRONG/g; s/port=13301;/port=13302;/g' faults.cfg > faults_13302_badpass.cfg
	for v in 2.11 1.10; do
		c=ndbt-tnt$(echo $v | tr -d .)
		podman rm -f $c >/dev/null 2>&1
		rm -rf tdata_$v; mkdir -p tdata_$v; chmod 777 tdata_$v
		podman run -d --name $c --network host --cpuset-cpus=0-1 -v /var/tmp/ndbt:/data:Z -w /data/tdata_$v \
			-e TNT_PORT=13302 --entrypoint tarantool docker.io/tarantool/tarantool:$v /data/init.lua >/dev/null
		sleep 3
		printf 'vers-%s\ttarantool=%s\t%s\n' $v "$(podman inspect -f '{{.State.Status}}' $c)" \
			"$(podman logs $c 2>&1 | grep -E 'version|E>|error' | head -2 | tr '\n' ' ' | cut -c1-200)" | tee -a $RES
		kam_start ndbt-kam-faults faults_13302.cfg
		for p in p_types p_inject p_unicode p_badjson p_after p_err p_nil p_multi p_slow p_short_ok p_big p_seq_a; do
			probe vers-$v $p "v-$p@h"
		done
		klog ndbt-kam-faults > $OUT/vers-$v/kamailio.log
		kam_stop ndbt-kam-faults
		kam_start ndbt-kam-faults faults_13302_badpass.cfg
		probe vers-$v-badpass p_after 'v-bad@h'
		klog ndbt-kam-faults > $OUT/vers-$v-badpass/kamailio.log
		kam_stop ndbt-kam-faults
		podman logs $c > $OUT/vers-$v/tarantool.log 2>&1
		podman rm -f $c >/dev/null
	done
	;;
esac; done
echo "=== done $(date +%T)" | tee -a $RES
