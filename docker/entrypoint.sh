#!/usr/bin/env bash
# The only file this repo adds to Bitnami's image: make the mounted disk writable by the uid
# that will actually run Redis, then hand off to Bitnami, which drops privileges itself.
#
# Why it is needed (X6): a Render persistent disk is mounted root:root, and Bitnami's own
# fix-up (redis_configure_permissions in libredis.sh) is a NON-recursive chown of the data
# dir. The AOF lives in appendonlydir/ underneath it, and it is that subdirectory Redis
# writes to several times a second. Left alone, the container starts, prints a normal-looking
# banner, loads its AOF read-only and then fails on the first write - a queue that merely
# looked durable. Recursive, on every boot, is the only version that also heals a disk
# written by an older container.
set -euo pipefail

DATA_DIR="${REDIS_DATA_DIR:-/bitnami/redis/data}"
DAEMON_USER="${REDIS_DAEMON_USER:-redis}"
DAEMON_GROUP="${REDIS_DAEMON_GROUP:-root}"

log() { printf '[redis-entrypoint] %s\n' "$*"; }

if [[ "$(id -u)" == "0" ]]; then
  mkdir -p "$DATA_DIR"
  if chown -R "$DAEMON_USER:$DAEMON_GROUP" "$DATA_DIR" 2>/dev/null; then
    # gid 0 keeps the disk usable if the image is ever moved back to a numeric-user start.
    chmod -R g+rwX "$DATA_DIR" 2>/dev/null || true
    log "$DATA_DIR is writable by $DAEMON_USER:$DAEMON_GROUP"
  else
    log "WARN: could not chown $DATA_DIR (not a root mount?); continuing"
  fi
else
  # Running as an arbitrary uid (OpenShift / Render someday tightening the policy): the disk
  # must already be owned, and a read-only mount is a hard failure, not a warning.
  if [[ ! -w "$DATA_DIR" ]]; then
    log "FATAL: $DATA_DIR is not writable by uid $(id -u) and we are not root, so the AOF cannot be created."
    log "       On Render, keep USER root in the Dockerfile; do not override dockerCommand."
    exit 1
  fi
  log "running as uid $(id -u); $DATA_DIR is writable"
fi

exec "$@"
