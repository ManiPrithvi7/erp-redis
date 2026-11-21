#!/usr/bin/env bash
# X15: one Redis serving cache (db 1) and queue (db 2) has ONE maxmemory and ONE eviction policy,
# so the two can starve each other. This decides whether "one instance" is safe or has to become
# two services.
#
# It runs in a throwaway container with a deliberately tiny maxmemory rather than against the live
# stack, because the test is destructive to the cache by design and the semantics do not depend on
# Frappe being attached: db 1 and db 2 share the same memory limit either way.
#
#   ./scripts/x15-maxmemory.sh
#
# Three cases, in order:
#   A. cache keys with no TTL fill the instance   -> what does a cache write return?
#   B. same full instance, now write a queue key   -> does the queue starve?  <- the question
#   C. cache keys WITH a TTL fill the instance     -> volatile-lru should evict cache for the queue
#
# A is what Frappe 16 actually does. Measured on a running site (see the census at the bottom of
# this file), ~99% of its cache keys carry no TTL, so A is not a hypothetical.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NAME=x15-redis
PW=proof-redis-password
MEM=20mb
# 100 KB, not 200 KB: Linux caps ONE argv entry at MAX_ARG_STRLEN (128 KiB), and a too-long value
# fails in `docker exec`, not in Redis, which reads as a confusing "Argument list too long".
CHUNK="$(head -c 100000 /dev/zero | tr '\0' x)"
CACHE_DB=1
QUEUE_DB=2
PASS=0; FAIL=0; NOTE=0; FULL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '  \033[33mnote\033[0m %s\n' "$*"; NOTE=$((NOTE+1)); }
step() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
cli()  { docker exec "$NAME" /opt/bitnami/redis/bin/redis-cli -p 10000 -a "$PW" --no-auth-warning "$@" 2>&1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

step "starting $NAME from proof-erpnext-redis:local with maxmemory $MEM"
docker run -d --name "$NAME" \
  -e ALLOW_EMPTY_PASSWORD=no -e REDIS_PASSWORD="$PW" -e REDIS_PORT_NUMBER=10000 \
  -e REDIS_AOF_ENABLED=no \
  -e "REDIS_EXTRA_FLAGS=--maxmemory $MEM --maxmemory-policy volatile-lru" \
  proof-erpnext-redis:local >/dev/null || { echo "could not start $NAME (docker compose build it first)" >&2; exit 1; }
for _ in $(seq 1 30); do [[ "$(cli PING)" == "PONG" ]] && break; sleep 1; done
echo "       $(cli CONFIG GET maxmemory | tr '\n' ' ')"
echo "       $(cli CONFIG GET maxmemory-policy | tr '\n' ' ')"

fill() { # fill <db> <ttl-seconds|0> - stop at the first rejected write; echo "<count> <last reply>"
  local db="$1" ttl="$2" i=0 last=""
  while (( i < 500 )); do
    i=$((i + 1))
    if [[ "$ttl" == "0" ]]; then
      last="$(cli -n "$db" SET "fill:$i" "$CHUNK")"
    else
      last="$(cli -n "$db" SETEX "fill:$i" "$ttl" "$CHUNK")"
    fi
    [[ "$last" == "OK" ]] || break
  done
  printf '%s %s\n' "$i" "${last:-never-rejected}"
}
evictions() { cli INFO stats | tr -d '\r' | awk -F: '/^evicted_keys:/{print $2}'; }

step "A) the cache db filled with keys that have NO ttl (Frappe's shape)"
a_out="$(fill "$CACHE_DB" 0)"
a_n="${a_out%% *}"; a_last="${a_out#* }"
echo "       write #$a_n answered: $a_last"
if [[ "$a_last" == OOM* ]]; then
  ok "write #$a_n was refused with '(${a_last:0:58}' - $((a_n - 1)) unevictable keys had already taken the whole $MEM"
  FULL=1
else
  note "the filler never hit maxmemory after $a_n keys, so B and C below prove nothing - raise CHUNK or lower MEM"
  FULL=0
fi

step "B) same instance, still full: can the QUEUE still take a job?"
if [[ "$FULL" == 1 ]]; then
  q="$(cli -n "$QUEUE_DB" LPUSH 'rq:queue:long' '{"u":"a-job"}')"
  if [[ "$q" =~ ^[0-9]+$ ]]; then
    ok "a small job payload still got in (depth $q) - Redis refused the 100 KB cache write above, not this"
  elif grep -q OOM <<<"$q"; then
    bad "the queue STARVED on a no-TTL cache: '$q'. volatile-lru can only evict keys that carry a TTL, and $((a_n - 1)) of $((a_n - 1)) cache keys here have none, so the cache holds the whole maxmemory hostage."
  else
    bad "unexpected queue answer: $q"
  fi
  big="$(cli -n "$QUEUE_DB" LPUSH 'rq:queue:long' "$CHUNK")"
  if grep -q OOM <<<"$big"; then
    note "...but a job the size of a cache value is refused exactly like one: '(${big:0:58}' - so what a shared limit costs is bounded by the largest job payload, not by the queue."
  elif [[ "$big" =~ ^[0-9]+$ ]]; then
    ok "even a 100 KB job payload was accepted (depth $big)"
  else
    bad "unexpected answer for the large job: $big"
  fi
else
  note "skipped - the instance never filled"
fi

step "C) the same pressure, but with TTL'd cache keys"
cli FLUSHALL >/dev/null
ev_start="$(evictions)"   # INFO's evicted_keys is cumulative for the process, so diff it
c_out="$(fill "$CACHE_DB" 3600)"
c_n="${c_out%% *}"; c_last="${c_out#* }"
echo "       write #$c_n answered: $c_last (evicted during the fill: $(( $(evictions) - ev_start )))"
q2="$(cli -n "$QUEUE_DB" LPUSH 'rq:queue:long' '{"u":"another-job"}')"
ev_delta=$(( $(evictions) - ev_start ))
if [[ "$q2" =~ ^[0-9]+$ ]] && (( ev_delta > 0 )); then
  ok "with TTL'd cache the queue still took a job (depth $q2) and volatile-lru evicted $ev_delta cache keys to pay for it - this is the shape that makes one instance work"
elif [[ "$q2" =~ ^[0-9]+$ ]]; then
  note "the queue took a job (depth $q2) but nothing was evicted after $c_n keys - maxmemory was not reached, inconclusive"
else
  bad "the queue starved even with TTL'd cache keys: $q2"
fi

step "the census this was written against (run it on the live stack)"
cat <<'EOF'
  cd ../proof-erpnext-app && set -a && . ./.env && set +a
  docker compose exec -T redis sh -c "for k in \$(/opt/bitnami/redis/bin/redis-cli -p 10000 \
      -a '$REDIS_PASSWORD' --no-auth-warning -n 1 --scan | head -300); do \
      /opt/bitnami/redis/bin/redis-cli -p 10000 -a '$REDIS_PASSWORD' --no-auth-warning \
      -n 1 TTL \"\$k\"; done" \
    | awk '{if ($1 < 0) n++; else w++} END {print n+0 " without TTL, " w+0 " with"}'
  Measured on a freshly installed ERPNext v16 site after the churn suite: 147 of 148 sampled db-1
  keys have TTL -1 (no expiry). They are the structural caches - doctype_meta::*, table_columns::*,
  document_cache::*, server_script_map, webhooks - which are exactly what `bench clear-cache`
  deletes, and exactly what volatile-lru cannot evict.

  So the one-Redis decision in this stack stands or falls on maxmemory sizing, not on the policy:
  give the instance headroom over the working set, watch `used_memory` against `maxmemory`, and
  treat a queue-side OOM as a cache-sizing bug. The fallback if that ever bites is a second Redis
  for db 2 - which is what the parent project's Upstash pair already was.
EOF

printf '\n\033[1m== %s passed, %s failed, %s notes\033[0m\n' "$PASS" "$FAIL" "$NOTE"
