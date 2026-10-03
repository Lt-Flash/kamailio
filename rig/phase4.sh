#!/bin/bash
# Phase 4 for kamailio#4913: sanitizers + soak. Runs on 223 from /var/tmp/ndbt.
#   ./phase4.sh [stage...]   stages: asan_probes asan_soak rel_soak restarts   (default: all)
# Needs: images ndbt-kam:asan-sys (ASan+UBSan, MEMPKG=sys so pkg_malloc is libc malloc) and
# ndbt-kam:rel; ndbt-tnt running; GENS remote SIPp generators with gen.sh staged (phase2.sh does it).
# Output: p4/results.txt + per-stage dirs; sanitizer reports in p4/<stage>/san/.
# NOTE: Kamailio workers leave with _exit(0) on SIGTERM (core/main.c), which skips
# LeakSanitizer - leak evidence comes from pkg.stats deltas on the release build.
set -u
set -o pipefail
cd /var/tmp/ndbt
OUT=${OUT:-p4}; mkdir -p $OUT
RES=$OUT/results.txt
GENS=${GENS:-"GEN_A:12 GEN_B:6"}
TARGET=SUT_IP:5060
SOAK_S=${SOAK_S:-1800}
SOAK_CPS=${SOAK_CPS:-5000}
RESTARTS=${RESTARTS:-100}
ASAN_IMG=localhost/ndbt-kam:asan-sys
REL_IMG=localhost/ndbt-kam:rel
SANOPTS="--cap-add SYS_PTRACE --security-opt seccomp=unconfined"

log() { echo "$(date +%T) $*" | tee -a $OUT/driver.log; }
res() { echo "$*" | tee -a $RES; }
san_env() {   # dir inside /data for sanitizer logs
	echo "-e ASAN_OPTIONS=detect_leaks=1:halt_on_error=0:abort_on_error=0:log_path=/data/$1/asan -e UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=0:log_path=/data/$1/ubsan -e LSAN_OPTIONS=log_threads=0"
}
san_count() {   # dir -> "asan=N ubsan=N leak=N files=N" (reports, not warnings)
	local d=$1
	local a u l f
	f=$(ls $d 2>/dev/null | wc -l)
	# ASan/LSan reports can land in ubsan.* files and UBSan reports only on stderr
	# (the Kamailio log) in a combined build: count across everything.
	a=$(cat $d/* 2>/dev/null | grep -c 'ERROR: AddressSanitizer')
	l=$(cat $d/* 2>/dev/null | grep -c 'ERROR: LeakSanitizer')
	u=$(cat $d/* $d/../kamailio.log $d/../*/kamailio.log 2>/dev/null | grep -c 'runtime error:')
	echo "asan_errors=$a leak_reports=$l ubsan_errors=$u report_files=$f"
}
san_top() {   # first frames that mention the module, for the report
	cat $1/asan.* $1/ubsan.* 2>/dev/null | grep -E 'ERROR:|runtime error:|#[0-9]+ .*(ndb_tarantool|tarantool_)' | head -${2:-20}
}

# remote load, one ssh per generator host
load_start() {   # tag cps seconds service data
	local tag=$1 cps=$2 secs=$3 svc=$4 data=$5 g h n NT=0
	for g in $GENS; do NT=$((NT + ${g##*:})); done
	LOAD_PIDS=(); LOAD_HOSTS=()
	for g in $GENS; do
		h=${g%%:*}; n=${g##*:}; LOAD_HOSTS+=($h)
		ssh -n -o BatchMode=yes $h "/var/tmp/ndbt-gen/gen.sh start $tag $n $((cps / NT)) $((cps * secs / NT)) $svc $data 15100 $h $secs $TARGET" &
		LOAD_PIDS+=($!)
	done
}
load_wait_summary() {   # tag -> "ok fail"
	local tag=$1 h ok=0 fail=0 a b
	wait "${LOAD_PIDS[@]}"
	for h in "${LOAD_HOSTS[@]}"; do
		read -r a b < <(ssh -n -o BatchMode=yes $h "/var/tmp/ndbt-gen/gen.sh summary $tag" | head -1)
		ok=$((ok + a)); fail=$((fail + b))
		ssh -n -o BatchMode=yes $h "/var/tmp/ndbt-gen/gen.sh clean $tag"
	done
	echo "$ok $fail"
}

kam_run() {   # name image cfgdefs extra-podman-opts
	podman rm -f $1 >/dev/null 2>&1
	podman run -d --name $1 --network host --cpuset-cpus=4-9 -v /var/tmp/ndbt:/data:Z $4 $2 \
		kamailio -f /data/bench.cfg -DD -E $3 -A WITH_LAN >/dev/null
	sleep 5
}
kam_stop() { podman logs $1 > $2/kamailio.log 2>&1; podman stop -t 30 $1 >/dev/null 2>&1; podman logs $1 > $2/kamailio.log 2>&1; podman rm -f $1 >/dev/null 2>&1; }
kam_hostpids() { pgrep -f '^kamailio -f /data/bench.cfg' | tr '\n' ' '; }
pss_kb() { local t=0 p; for p in "$@"; do [ -r /proc/$p/smaps_rollup ] && t=$((t + $(awk '/^Pss:/ {print $2}' /proc/$p/smaps_rollup))); done; echo $t; }
fds() { local p; for p in "$@"; do echo -n "$(ls /proc/$p/fd 2>/dev/null | wc -l) "; done; }
pkgstats() {   # "pid used" per process (exactly the used: field, not real_used:)
	podman exec $1 kamcmd -s unix:/tmp/kamailio_ctl pkg.stats 2>/dev/null | awk '$1 == "pid:" {p=$2} $1 == "used:" {print p, $2}' | sort -n
}
cdr_check() {   # dir data -> "answers correct wrong" (loopback, from 223)
	local d=$1 data=$2
	{ echo SEQUENTIAL; tail -n +2 $data/callers.csv | head -200; } > $d/callers_seq.csv
	timeout 120 sipp 127.0.0.1:5060 -sf cdr_check.xml -s cdr -inf $d/callers_seq.csv -m 200 -r 200 -l 50 \
		-i 127.0.0.1 -p 15098 -nostdin -recv_timeout 5000 -trace_logs -log_file $d/check.log >/dev/null 2>&1
	python3 - $d/check.log $data/expected.tsv <<'PY'
import re, sys
exp = dict(l.rstrip("\n").split("\t") for l in open(sys.argv[2]))
ok = bad = 0
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"CHK (\S+) (\S*)", l)
    if m:
        good = exp.get(m.group(1)) in (m.group(2), m.group(2).strip('"'))
        ok += good; bad += not good
print(f"answers={ok + bad}/200 correct={ok} wrong={bad}")
PY
}
tnt_load() {   # dataset rows
	podman rm -f ndbt-tnt >/dev/null 2>&1
	rm -rf tdata && mkdir -p tdata && chmod 777 tdata
	podman run -d --name ndbt-tnt --network host --cpuset-cpus=0-1 -v /var/tmp/ndbt:/data:Z -w /data/tdata \
		-e TNT_PORT=13301 -e CDR_TSV=/data/$1/cdr.tsv --entrypoint env docker.io/tarantool/tarantool:3 \
		-u TT_INSTANCE_NAME -u TT_APP_NAME tarantool /data/init.lua >/dev/null
	local i
	for i in $(seq 1 60); do
		[ "$(echo 'box.space.cdr:len()' | podman exec -i ndbt-tnt tt connect kam:kampass@127.0.0.1:13301 -f - 2>/dev/null | grep -Eo '[0-9]+' | head -1)" = "$2" ] && break
		sleep 2
	done
	log "tarantool $1 loaded ($2 rows)"
}

STAGES=${*:-asan_probes asan_soak rel_soak restarts}
log "=== phase4 start: stages=$STAGES soak=${SOAK_S}s@${SOAK_CPS}cps restarts=$RESTARTS gens=$GENS"
for img in $ASAN_IMG $REL_IMG; do log "$img: $(podman run --rm $img cat /BUILD_REV | head -2 | tr '\n' ' ')"; done
echo "=== $(date '+%F %T %Z') stages=$STAGES" >> $RES

for st in $STAGES; do case $st in

asan_probes)   # Phase 1 probe stages under ASan+UBSan with libc pkg malloc
	d=$OUT/asan_probes; mkdir -p $d/san; chmod 777 $d/san
	tnt_load d5k 5000
	OUT=$d IMG=$ASAN_IMG KAM_OPTS="$SANOPTS $(san_env $d/san)" ./phase1.sh basic slow big addr conns restart > $d/phase1.out 2>&1
	res "asan_probes	$(san_count $d/san)	probes=$(grep -cP '\t' $d/results.txt 2>/dev/null)"
	san_top $d/san > $d/san_top.txt
	;;

asan_soak)   # 30 min CDR load at SOAK_CPS on the 500k dataset under ASan
	d=$OUT/asan_soak; mkdir -p $d/san; chmod 777 $d/san
	tnt_load d500k 500000
	kam_run ndbt-kam-p4 $ASAN_IMG "-A WITH_TNT" "$SANOPTS $(san_env $d/san)"
	kp=$(kam_hostpids)
	log "asan soak start: $(echo $kp | wc -w) kamailio processes, PSS $(pss_kb $kp) kB"
	load_start p4_asan_soak $SOAK_CPS $SOAK_S cdr d500k
	for i in $(seq 1 $((SOAK_S / 60))); do sleep 60; echo "$(date +%T) min=$i pss_kB=$(pss_kb $kp) fds=[$(fds $kp)]" >> $d/samples.txt; done
	read -r ok fail < <(load_wait_summary p4_asan_soak)
	kam_stop ndbt-kam-p4 $d
	res "asan_soak	ok=$ok fail=$fail	$(san_count $d/san)	pss_kB_first=$(head -1 $d/samples.txt | grep -o 'pss_kB=[0-9]*' | cut -d= -f2) last=$(tail -1 $d/samples.txt | grep -o 'pss_kB=[0-9]*' | cut -d= -f2)"
	san_top $d/san > $d/san_top.txt
	;;

rel_soak)   # 30 min on the release build: pkg used per process + fds, start vs end, then correctness
	d=$OUT/rel_soak; mkdir -p $d
	tnt_load d500k 500000
	kam_run ndbt-kam-p4 $REL_IMG "-A WITH_TNT -A WITH_CTL" ""
	kp=$(kam_hostpids)
	pkgstats ndbt-kam-p4 > $d/pkg_start.txt; fds $kp > $d/fds_start.txt
	load_start p4_rel_soak $SOAK_CPS $SOAK_S cdr d500k
	for i in $(seq 1 $((SOAK_S / 60))); do sleep 60; echo "$(date +%T) min=$i pss_kB=$(pss_kb $kp) fds=[$(fds $kp)]" >> $d/samples.txt; done
	read -r ok fail < <(load_wait_summary p4_rel_soak)
	pkgstats ndbt-kam-p4 > $d/pkg_end.txt; fds $kp > $d/fds_end.txt
	chk=$(cdr_check $d d500k)
	kam_stop ndbt-kam-p4 $d
	growth=$(join $d/pkg_start.txt $d/pkg_end.txt | awk '{g = $3 - $2; if (g > m) m = g; t += g} END {printf "max_per_process=%d total=%d", m, t}')
	res "rel_soak	ok=$ok fail=$fail	pkg_used_growth_bytes: $growth	fds_start=[$(cat $d/fds_start.txt)] fds_end=[$(cat $d/fds_end.txt)]	$chk"
	;;

restarts)   # RESTARTS Tarantool restarts under 1k cps; fds and correctness after
	d=$OUT/restarts; mkdir -p $d
	tnt_load d5k 5000
	kam_run ndbt-kam-p4 $REL_IMG "-A WITH_TNT -A WITH_CTL" ""
	kp=$(kam_hostpids)
	fds $kp > $d/fds_start.txt; pkgstats ndbt-kam-p4 > $d/pkg_start.txt
	secs=$((RESTARTS * 8 + 30))
	load_start p4_restarts 1000 $secs cdr d5k
	sleep 10
	for i in $(seq 1 $RESTARTS); do podman restart -t 2 ndbt-tnt >/dev/null 2>&1; sleep 6; echo "$(date +%T) restart=$i fds=[$(fds $kp)]" >> $d/samples.txt; done
	read -r ok fail < <(load_wait_summary p4_restarts)
	sleep 12   # let disable_time expire before the check
	fds $kp > $d/fds_end.txt; pkgstats ndbt-kam-p4 > $d/pkg_end.txt
	chk=$(cdr_check $d d5k)
	estab=$(ss -Htn state established '( dport = :13301 )' | wc -l)
	kam_stop ndbt-kam-p4 $d
	growth=$(join $d/pkg_start.txt $d/pkg_end.txt | awk '{g = $3 - $2; if (g > m) m = g; t += g} END {printf "max_per_process=%d total=%d", m, t}')
	res "restarts	n=$RESTARTS ok=$ok fail=$fail	fds_start=[$(cat $d/fds_start.txt)] fds_end=[$(cat $d/fds_end.txt)]	conns_after=$estab	pkg_used_growth_bytes: $growth	$chk"
	;;
esac; done

tnt_load d5k 5000   # leave the 5k dataset, as RESUME.md describes
log "=== phase4 done"
touch $OUT/DONE
