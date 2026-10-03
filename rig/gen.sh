#!/bin/bash
# Remote SIPp load-generator helper for phase2.sh (lives in /var/tmp/ndbt-gen on each generator).
# One ssh per generator host per action: sshd's MaxStartups refuses bursts of parallel sessions.
#   gen.sh start   TAG N RATE CALLS SERVICE DATA PORTBASE LOCAL_IP STEP_S TARGET
#                  runs N SIPp instances (RATE / CALLS each) and returns when all have ended
#   gen.sh succ    TAG     -> successful calls so far, summed over this host's instances
#   gen.sh summary TAG     -> "ok fail" then one "ms count" line per response-time value (merged)
#   gen.sh rcvbuf          -> host-wide UDP RcvbufErrors
#   gen.sh clean   TAG
G=/var/tmp/ndbt-gen
cmd=$1; tag=$2
R=$G/run/$tag
case $cmd in
start)
	n=$3 rate=$4 calls=$5 svc=$6 data=$7 portbase=$8 ip=$9 step_s=${10} target=${11}
	pids=()
	for k in $(seq 0 $((n - 1))); do
		mkdir -p $R/s$k
		( cd $R/s$k && exec setsid env LD_LIBRARY_PATH=$G/lib timeout $((step_s + 60)) $G/sipp $target \
			-sf $G/cdr_uac.xml -s $svc -inf $G/$data/callers.csv \
			-r $rate -m $calls -l $((rate * 2 + 100)) -i $ip -p $((portbase + 10 * k)) -nostdin \
			-recv_timeout 3000 -buff_size 8388608 \
			-trace_rtt -rtt_freq 1000 -trace_stat -fd 1 -stf stat.csv </dev/null >/dev/null 2>&1 ) &
		pids+=($!)
	done
	wait "${pids[@]}"
	;;
succ)
	python3 - $R <<'PY'
import csv, glob, sys
t = 0
for f in glob.glob(f"{sys.argv[1]}/s*/stat.csv"):
    try:
        r = list(csv.reader(open(f), delimiter=";"))
        t += int(r[-1][r[0].index("SuccessfulCall(C)")])
    except Exception:
        pass
print(t)
PY
	;;
summary)
	python3 - $R <<'PY'
import csv, glob, sys, collections
R = sys.argv[1]
ok = fail = 0
for f in glob.glob(f"{R}/s*/stat.csv"):
    try:
        r = list(csv.reader(open(f), delimiter=";"))
        h = r[0]
        ok += int(r[-1][h.index("SuccessfulCall(C)")])
        fail += int(r[-1][h.index("FailedCall(C)")])
    except Exception:
        pass
print(ok, fail)
hist = collections.Counter()
for f in glob.glob(f"{R}/s*/*_rtt.csv"):
    for line in open(f):
        p = line.strip().split(";")
        if len(p) >= 3:
            try:
                hist[float(p[2])] += 1
            except ValueError:
                pass
for k in sorted(hist):
    print(k, hist[k])
PY
	;;
rcvbuf)
	awk '$1 == "Udp:" && $2 ~ /^[0-9]+$/ {print $6; found = 1} END {if (!found) print 0}' /proc/net/snmp
	;;
clean)
	rm -rf $R
	;;
esac
