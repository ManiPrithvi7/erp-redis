# Proof repo: Bitnami Redis as a Render private service - ONE instance serving Frappe's
# cache (logical DB 1) and its job queue (logical DB 2), with the AOF on a persistent disk.
#
# Pinned by digest on purpose: bitnami/redis publishes `latest` only since the 28 Aug 2025
# catalog cut-over, and the immutable tags moved to bitnamilegacy (frozen 2025-07-18).
# A proof repo has to be reproducible; RENDER_DEPLOY.md has the re-pin procedure and the two
# alternative FROM lines (bitnamisecure/redis:latest, redis:7-alpine).
FROM docker.io/bitnamilegacy/redis@sha256:7bb474599fb0af96c8c0aeddc20f824293d9090c4e511a2dded0bb84ee5260f7
# ^ = bitnamilegacy/redis:7.2-debian-12

# The image's default USER is the numeric uid 1001, so editing /etc/passwd must opt into root
# first - a RUN before this line dies with useradd exit 10 ("can't update /etc/passwd").
USER root

# This line is the whole reason the repo has a Dockerfile (X6, measured locally).
# uid 1001 has no /etc/passwd entry in this image, while Bitnami's REDIS_DAEMON_USER is the
# *name* "redis". Start it as root without this line and setup.sh's `ensure_user_exists redis`
# invents a user with a different uid (Debian hands out the first free one, ~100), so run.sh
# drops to a uid owning nothing on the disk: Redis loads the AOF read-only, prints a normal
# banner, then dies on the first write with "Can't open the append-only file appendonly.aof.1.
# incr.aof: Permission denied". Pinning the name to the uid the image already uses keeps one
# identity across root and non-root starts, and across a disk written by either.
RUN set -eux; \
    getent group redis >/dev/null 2>&1 || groupadd --gid 1001 redis; \
    getent passwd redis >/dev/null 2>&1 || \
      useradd --uid 1001 --gid 0 --no-create-home --home-dir /opt/bitnami/redis \
              --shell /sbin/nologin redis

# Staying root is deliberate: root is needed on every boot to make a freshly attached Render
# disk writable (docker/entrypoint.sh), and redis-server still ends up as uid 1001 because
# Bitnami's own run.sh performs the drop via `chroot --userspec`.
COPY docker/entrypoint.sh /opt/render/entrypoint.sh
RUN chmod 0755 /opt/render/entrypoint.sh

# Everything Redis needs is re-rendered into /opt/bitnami/redis/etc/redis.conf on every boot
# from Bitnami's env vars, so nothing has to be baked - and baking a redis.conf would be
# actively wrong here: libredis.sh skips redis_override_conf() when a mounted conf is present,
# which would silently disable REDIS_AOF_ENABLED and REDIS_PORT_NUMBER.
#
# maxmemory / maxmemory-policy are the two settings with NO Bitnami env var; run.sh appends
# REDIS_EXTRA_FLAGS after the conf path and Redis lets the last occurrence win. volatile-lru is
# what makes one instance safe for both cache and queue: it can evict the TTL'd cache keys in
# db 1 while the non-expiring RQ job keys in db 2 stay put (X15).
ENV REDIS_AOF_ENABLED=yes \
    REDIS_EXTRA_FLAGS="--maxmemory 200mb --maxmemory-policy volatile-lru"

ENTRYPOINT ["/opt/render/entrypoint.sh"]
CMD ["/opt/bitnami/scripts/redis/entrypoint.sh", "/opt/bitnami/scripts/redis/run.sh"]
