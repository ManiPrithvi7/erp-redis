#!/usr/bin/env bash
# X6, reproduced for free: a Redis that only LOOKS durable because its data directory is not
# writable by the uid that redis-server runs as.
#
# A Render persistent disk is mounted root:root. That is the same shape as a named volume
# used by a container whose user has no write access to it, so both variants below run against
# a deliberately unwritable mount and the only difference is the image.
#
#   ./scripts/x6-repro.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VOL=proof-x6-data
STOCK=docker.io/bitnamilegacy/redis@sha256:7bb474599fb0af96c8c0aeddc20f824293d9090c4e511a2dded0bb84ee5260f7
PW=proof-redis-password
cleanup() { docker rm -f x6-a x6-b >/dev/null 2>&1 || true; }
cleanup
trap cleanup EXIT

echo "=== preparing an unwritable data volume (root:root, no group write) ==="
docker volume create "$VOL" >/dev/null
docker run --rm --user 0 -v "$VOL":/d alpine sh -c 'rm -rf /d/* 2>/dev/null; mkdir -p /d/appendonlydir; chown -R root:root /d; chmod 755 /d /d/appendonlydir; ls -ld /d /d/appendonlydir'

echo
echo "=== A) stock Bitnami image, dropped to uid 1001 (what Render gives a root-owned disk) ==="
docker run -d --name x6-a -v "$VOL":/bitnami/redis/data --user 1001:1001 \
  -e ALLOW_EMPTY_PASSWORD=no -e REDIS_PASSWORD="$PW" -e REDIS_PORT_NUMBER=10000 \
  -e REDIS_AOF_ENABLED=yes "$STOCK" >/dev/null 2>&1 || true
sleep 6
echo "--- what it printed ---"
docker logs x6-a 2>&1 | grep -iE "warn|error|denied|ready|fatal|Can't|Cannot|Invalid" | head -8 | sed 's/^/  /' || echo "  (no container - it refused to start)"
if docker exec x6-a /opt/bitnami/redis/bin/redis-cli -p 10000 -a "$PW" --no-auth-warning SET x6:probe 1 >/dev/null 2>&1; then
  echo "  RESULT: writes were accepted (the mount happened to be usable)"
else
  echo "  RESULT: could not write - this is X6. Note that 'SET' failing here is loud, but a"
  echo "          BGREWRITEAOF/MISCONF failure only shows up hours later, under memory pressure."
fi
docker rm -f x6-a >/dev/null 2>&1

echo
echo "=== B) this repo's image (USER root -> chown -R -> Bitnami drops to uid 1001 itself) ==="
docker run -d --name x6-b -v "$VOL":/bitnami/redis/data \
  -e ALLOW_EMPTY_PASSWORD=no -e REDIS_PASSWORD="$PW" -e REDIS_PORT_NUMBER=10000 \
  -e 'REDIS_EXTRA_FLAGS=--maxmemory 200mb --maxmemory-policy volatile-lru' \
  proof-erpnext-redis:local >/dev/null 2>&1 || true
sleep 6
echo "--- entrypoint line ---"
docker logs x6-b 2>&1 | grep -E 'redis-entrypoint|Can.t open|denied|MISCONF|Ready to accept' | head -6 | sed 's/^/  /'
if docker exec x6-b /opt/bitnami/redis/bin/redis-cli -p 10000 -a "$PW" --no-auth-warning SET x6:probe ok >/dev/null 2>&1 \
   && docker exec x6-b /opt/bitnami/redis/bin/redis-cli -p 10000 -a "$PW" --no-auth-warning BGREWRITEAOF >/dev/null 2>&1; then
  echo "  RESULT: writable, and a manual AOF rewrite succeeds - the queue is genuinely durable"
  docker exec x6-b ls -ld /bitnami/redis/data/appendonlydir | sed 's/^/  /'
else
  echo "  RESULT: still failing - build the image first (docker compose build) and re-run"
fi

echo
echo "Run 'docker volume rm $VOL' when done. The same shape on Render is measured by"
echo "proof-erpnext-app/scripts/persistence-check.sh --stage hard-kill."
