#!/bin/bash
# Recreate the ndb_tarantool test backends on 223 (run there, from /var/tmp/ndbt).
#   ./up.sh            start/restart ndbt-tnt (Tarantool 3, :13301) and ndbt-redis (Redis 8, :16399)
#   ./up.sh status     show both, with data counts
# Data: the CDR set in cdr.tsv / redis.resp (gen_cdr.py output; 5,000 rows / 200 callers today).
# Both run without persistence (Tarantool wal_mode=none, Redis no save/AOF): a restart reloads
# Tarantool from cdr.tsv automatically; Redis is reloaded here.
set -eu
cd /var/tmp/ndbt

status() {
	podman ps -a --format '{{.Names}}\t{{.Status}}' | grep -E '^ndbt-(tnt|redis)\b' || true
	echo "tarantool cdr rows: $(echo 'box.space.cdr:len()' | podman exec -i ndbt-tnt tt connect kam:kampass@127.0.0.1:13301 -f - 2>/dev/null | grep -Eo '[0-9]+' | head -1)"
	echo "redis keys: $(podman exec ndbt-redis redis-cli -p 16399 DBSIZE 2>/dev/null)"
}
[ "${1:-}" = status ] && { status; exit 0; }

podman rm -f ndbt-tnt ndbt-redis >/dev/null 2>&1 || true
rm -rf tdata && mkdir -p tdata && chmod 777 tdata

# TT_INSTANCE_NAME/TT_APP_NAME in the image switch Tarantool 3 to declarative config: unset them.
podman run -d --name ndbt-tnt --network host --cpuset-cpus=0-1 \
	-v /var/tmp/ndbt:/data:Z -w /data/tdata -e TNT_PORT=13301 -e CDR_TSV=/data/cdr.tsv \
	--entrypoint env docker.io/tarantool/tarantool:3 -u TT_INSTANCE_NAME -u TT_APP_NAME \
	tarantool /data/init.lua >/dev/null

podman run -d --name ndbt-redis --network host --cpuset-cpus=0-1 docker.io/library/redis:8 \
	redis-server --port 16399 --save "" --appendonly no --io-threads 2 >/dev/null
sleep 3
R="podman exec -i ndbt-redis redis-cli -p 16399"
$R FUNCTION LOAD REPLACE "$(cat voipbench.lua)" >/dev/null
$R FT.CREATE idx:cdr ON HASH PREFIX 1 cdr: SCHEMA src TAG ts NUMERIC SORTABLE >/dev/null
$R --pipe < redis.resp | tail -1
sleep 2
status
