#!/usr/bin/env bash
# Does this Redis actually persist? Checks the config it claims, the config it loaded, and
# then the only thing that counts: a marker written to each logical DB must still be there
# after a restart (planned and SIGKILL).
#
#   ./scripts/persist-check.sh
#
# db 1 = Frappe cache   -> allowed to be empty after a restart; TTL'd keys are the point
# db 2 = RQ job queue   -> must survive; this is the only store here that cannot be rebuilt
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] && set -a && . ./.env && set +a
PW="${REDIS_PASSWORD:-proof-redis-password}"
PORT="${REDIS_PORT_NUMBER:-10000}"

PASS=0; FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
line() { printf '\n== %s\n' "$*"; }
rcli() { docker compose exec -T redis redis-cli -p "$PORT" -a "$PW" --no-auth-warning "$@" 2>/dev/null; }

docker compose up -d --build >/dev/null || { echo "build/start failed" >&2; exit 1; }
sleep 4

line "identity (X6: the uid that writes must be the uid that owns)"
printf '  container uid/gid: %s\n' "$(docker compose exec -T redis id 2>/dev/null | tr -d '\r')"
printf '  redis-server owner: %s\n' "$(docker compose exec -T redis sh -c 'ps -o user=,pid=,comm= -C redis-server' 2>/dev/null | tr -d '\r')"
printf '  data dir: %s\n' "$(docker compose exec -T redis ls -ld /bitnami/redis/data /bitnami/redis/data/appendonlydir 2>&1 | tr '\n' ' ')"
if docker compose exec -T redis sh -c 'su -s /bin/sh -c "test -w /bitnami/redis/data/appendonlydir" redis' >/dev/null 2>&1 \
   || docker compose exec -T redis test -w /bitnami/redis/data/appendonlydir >/dev/null 2>&1; then
  ok "appendonlydir is writable by the running process"
else
  bad "appendonlydir is NOT writable - the queue would fail on its first write"
fi

line "config actually loaded (env var vs reality)"
for pair in "appendonly yes" "appendfsync everysec" "maxmemory-policy volatile-lru" "dir /bitnami/redis/data"; do
  key="${pair%% *}"; want="${pair#* }"
  got="$(rcli CONFIG GET "$key" | tail -n 1 | tr -d '\r')"
  [[ "$got" == "$want" ]] && ok "$key = $got" || bad "$key = '${got:-unset}', want $want"
done
# `save ""` in the shipped conf means there is no RDB safety net: the AOF is the whole story.
printf '  save points: %s (empty = AOF-only)\n' "$(rcli CONFIG GET save | tail -n1 | tr -d '\r' | tr '\n' ' ')"

line "persistence report"
rcli INFO persistence 2>/dev/null | grep -E '^(aof_enabled|aof_last_bgrewrite_status|aof_last_write_status|rdb_last_bgsave_status):' | sed 's/^/  /'
[[ "$(rcli INFO persistence | grep '^aof_enabled:' | tr -d '\r' | cut -d: -f2)" == "1" ]] \
  && ok "aof_enabled:1" || bad "aof_enabled is not 1"

line "markers in both logical DBs, then a restart"
UUID="$(cat /proc/sys/kernel/random/uuid)"
rcli -n 1 SET proof:cache "$UUID" EX 3600 >/dev/null
rcli -n 2 SET proof:queue "$UUID" >/dev/null
rcli -n 2 RPUSH rq:test "$UUID" >/dev/null
aof_before="$(docker compose exec -T redis sh -c 'ls -l /bitnami/redis/data/appendonlydir/* | awk "{print \$5}"' | tr -d '\r' | paste -sd+ | bc)"
printf '  AOF bytes on disk before restart: %s\n' "${aof_before:-?}"
rcli BGREWRITEAOF >/dev/null; sleep 2
printf '  after BGREWRITEAOF: %s\n' "$(rcli INFO persistence | grep -E '^aof_last_bgrewrite_status' | tr -d '\r')"

docker compose restart >/dev/null
sleep 4
c1="$(rcli -n 1 GET proof:cache | tr -d '\r')"
c2="$(rcli -n 2 GET proof:queue | tr -d '\r')"
l2="$(rcli -n 2 LLEN rq:test | tr -d '\r')"
[[ "$c2" == "$UUID" ]] && ok "db2 marker survived the restart (queue is durable)" || bad "db2 marker -> '${c2:-gone}'"
[[ "${l2:-0}" != "0" ]] && ok "db2 list survived (RQ job keys replay)" || bad "db2 list gone - RQ keys are not being replayed"
[[ "$c1" == "$UUID" ]] && ok "db1 marker also survived (fine; cache loss is acceptable)" || printf '  note: db1 marker gone (%s) - acceptable for cache\n' "${c1:-gone}"

line "SIGKILL (unclean: no final AOF flush)"
UUID2="$(cat /proc/sys/kernel/random/uuid)"
rcli -n 2 SET proof:kill "$UUID2" >/dev/null
# Write for ~1.2s then kill -9. Each write costs a `docker compose exec`, so the loop is slow
# enough that losing everything is not possible - what this measures is whether the AOF
# replays at all, and how many of the last-second writes make it.
: >/tmp/x6-issued
( for i in $(seq 1 30); do
    rcli -n 2 SET "proof:loop:$i" "$i" >/dev/null 2>&1 && printf '%s\n' "$i" >>/tmp/x6-issued
    sleep 0.05
  done ) &
WRITER=$!
sleep 1.2
docker kill -s KILL "$(docker compose ps -q redis)" >/dev/null 2>&1
wait $WRITER 2>/dev/null || true
issued="$(wc -l </tmp/x6-issued | tr -d ' ')"; rm -f /tmp/x6-issued
docker compose up -d >/dev/null; sleep 4
k="$(rcli -n 2 GET proof:kill | tr -d '\r')"
loops="$(rcli -n 2 KEYS 'proof:loop:*' | grep -c . || true)"
[[ "$k" == "$UUID2" ]] && ok "pre-kill marker survived SIGKILL (AOF replay)" || bad "lost the pre-kill marker on SIGKILL"
printf '  writes issued %s, recovered %s (appendfsync everysec may drop the last ~1s)\n' "${issued:-?}" "${loops:-0}"
loop_keys="$(rcli -n 2 --scan --pattern 'proof:loop:*')"
[[ -n "$loop_keys" ]] && rcli -n 2 DEL $loop_keys >/dev/null 2>&1  # word-split on purpose
rcli -n 2 DEL proof:kill >/dev/null

printf '\n== %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
