# Deploying this on Render

Deploy this service **first** — `erpnext-db` and `erpnext-app` are both configured with its
hostname, and neither can start cleanly without it.

## 1. Before you click anything

- One Render **project**, and every one of the three services in the **same region**. Private
  networking is same-project, same-region only.
- **The disk has to exist on the first deploy.** Render creates it with the service; adding it
  later mounts an *empty* volume over `/bitnami/redis/data`, which is indistinguishable from
  having lost the queue. Disks are grow-only, snapshotted daily with 7-day retention, those
  snapshots are not exportable, and **deleting the service deletes the disk permanently**.
- A disk also disables zero-downtime deploys for that service, which is why `render.yaml` sets
  `autoDeployTrigger: off`. Pushes should not be able to take your queue down.
- Unresolved at the time of writing: whether private services / disks / Blueprints need the
  $25/month **Pro workspace**. Check the price shown on the create screen before the first
  deploy, not after.

## 2. Create the service

Dashboard → New → **Blueprint** → connect `ManiPrithvi7/erpnext-redis`. The whole file is one
service, so there is nothing to deselect. It will prompt for one secret:

| variable | notes |
|---|---|
| `REDIS_PASSWORD` | goes into the URL the app service uses: `redis://default:<this>@<host>:10000` |

Everything else (`REDIS_PORT_NUMBER=10000`, `ALLOW_EMPTY_PASSWORD=no`, `REDIS_AOF_ENABLED=yes`,
`REDIS_EXTRA_FLAGS`) is already in `render.yaml` and does not need a dashboard value.

### Why port 10000 and not 6379 (X9)

A `pserv` has no `ports:` field in the [Blueprint spec](https://render.com/docs/blueprint-spec)
and gets a **TCP-only** health check against its *primary* port. So the process has to own that
port, and Render's convention for it is `$PORT`, i.e. 10000. Nothing else listens here, so
Bitnami's `REDIS_PORT_NUMBER` is simply set to match. The corollary: no HTTP health check, no
`/health` endpoint, and no path-based probe — TCP connect succeeding is the whole signal, which
is the right amount of information for an AUTH-protected Redis (it answers TCP before you
authenticate).

### Why the eviction policy is an env var and not a conf file

`maxmemory` and `maxmemory-policy` have **no** Bitnami env vars. The obvious fix — bake a
`redis.conf` into the image and include it — is actively wrong here: `libredis.sh` skips
`redis_override_conf()` entirely when a conf file is already mounted, which would silently
disable `REDIS_AOF_ENABLED` *and* `REDIS_PORT_NUMBER` and leave Redis listening on the wrong port
without persistence. The supported hook is `REDIS_EXTRA_FLAGS`: `run.sh` appends it *after* the
conf path, and Redis lets the last occurrence of a directive win.

## 3. Copy the internal hostname

After the first successful deploy the service's **Internal HTTP Application URL** / private
endpoint reads `erpnext-redis-<4char>` on port `10000`. That is what goes into
`proof-erpnext-app`'s `REDIS_URL`, **without** a database suffix:

```
redis://default:<REDIS_PASSWORD>@erpnext-redis-<4char>:10000
```

The app's `docker/entrypoint.sh` appends `/1` for `redis_cache` and `/2` for `redis_queue` and
`redis_socketio`. Keep that split in the image, not in the dashboard value: one URL, two logical
databases, and the ability to move to two instances later by changing one line of shell instead
of three env vars.

## 4. Verify it from inside the private network

Nothing here is reachable from your laptop, and `redis-cli` is not in the app image. Use the app
service's **Shell** tab and its Python:

```python
import os, redis
base = os.environ["REDIS_URL"]
for db in (1, 2):
    r = redis.from_url(f"{base}/{db}")
    print(db, r.ping(), r.config_get("maxmemory-policy"), r.config_get("appendonly"))
print(r.execute_command("INFO", "persistence")["aof_enabled"])
```

Expected: `maxmemory-policy = volatile-lru`, `appendonly = yes`, `aof_enabled = 1`.

Locally, `./scripts/persist-check.sh` asserts the same things plus the two that matter most —
that a marker in db 2 survives both a planned `restart` and a `kill -9`, and that the AOF
actually replays.

## 5. What survives what

| event | db 1 (cache) | db 2 (queue) |
|---|---|---|
| `restart` of the service | contents come back from the AOF, TTLs keep running | intact, pending jobs still execute |
| redeploy (new container, same disk) | same | same |
| disk recreated / service deleted | gone — fine, it is a cache | **gone — jobs are not recoverable** |
| `kill -9` mid-write | n/a | up to ~1 s of writes, because `appendfsync` is `everysec` |

Cache loss is a performance blip. Queue loss is a silently dropped email. That asymmetry is the
whole reason this repo has a disk and an entrypoint instead of `image: bitnami/redis` and nothing
else.

## 6. The image, and why it is frozen

Broadcom cut the Bitnami catalog over on 28 Aug 2025. What is actually on Docker Hub today:

| repo | `latest` | pinnable tags | state |
|---|---|---|---|
| `docker.io/bitnami/redis` | exists | none (`7.2-debian-12`, `8-debian-12` → 404) | rolling tag only |
| `docker.io/bitnamilegacy/redis` | exists | `7.2-debian-12` (~51 MB compressed) | **frozen 2025-07-18, zero updates** |
| `docker.io/bitnamisecure/redis` | exists | none public | updated 2026-11-04; commercial use needs a subscription |

There is no "minimal" Bitnami Redis flavour — the smallest Bitnami tag is bigger than the official
`redis:7-alpine` (~16 MB). This repo pins `bitnamilegacy/redis:7.2-debian-12` **by digest**
because a proof repo has to be reproducible; `latest`-only channels change underneath you and
would make every measured result unattributable.

```
FROM docker.io/bitnamilegacy/redis@sha256:7bb474599fb0af96c8c0aeddc20f824293d9090c4e511a2dded0bb84ee5260f7
```

To re-pin, or to switch channel:

```bash
# current digest of a tag, for any of the three repos:
docker buildx imagetools inspect docker.io/bitnamilegacy/redis:7.2-debian-12
docker buildx imagetools inspect docker.io/bitnamisecure/redis:latest      # tracked updates, paid
docker buildx imagetools inspect docker.io/library/redis:7-alpine          # smaller, actively maintained
```

Swap the `FROM` line only. The rest of the image (`REDIS_EXTRA_FLAGS`, `REDIS_AOF_ENABLED`) is
Bitnami-specific, so with the **official** `redis` image replace the env block with a real
`redis.conf` and drop `docker/entrypoint.sh`'s user name in favour of `chown -R 999` — and re-run
`persist-check.sh`, because the uid story changes completely.

## 7. The uid trap this image exists for (X6)

`REDIS_DAEMON_USER` is the *name* `redis`, but the image runs as the **numeric** uid 1001 with no
`/etc/passwd` entry. Start it as root without pinning that name and Bitnami's
`ensure_user_exists redis` invents a user, Debian hands out the first free uid (~100), and
`run.sh` then drops privileges to a uid that owns nothing on the disk. Redis loads the AOF
read-only, prints a normal-looking banner, and dies on the first write with
`Can't open the append-only file ...: Permission denied` — after which the queue is not durable
even though every setting says it is. Reproduce it in 30 seconds with `./scripts/x6-repro.sh`.

Two things fix it, both in this repo:

1. `useradd --uid 1001 --gid 0 redis` in the Dockerfile, so the name and the numeric uid are the
   same identity across root and non-root starts;
2. `chown -R redis:root /bitnami/redis/data` on every boot in `docker/entrypoint.sh` — recursive,
   because Bitnami's own `redis_configure_permissions` is a **non-recursive** chown of the data
   dir and the AOF lives in `appendonlydir/` underneath it.

Do not override `dockerCommand` in the dashboard: `render.yaml`'s `CMD` chain is what runs
Bitnami's entrypoint *after* the chown, and skipping it puts you back on the broken path.

## 8. Cost

`starter` (512 MB / 0.1 CPU) is enough for a Redis whose whole dataset is a cache plus a job
queue, and 5 GB of disk is ~$1.25/month. If `bench migrate` or a large export ever drives the
queue's memory past `maxmemory`, raise `REDIS_MAXMEMORY` in `REDIS_EXTRA_FLAGS` before raising
the plan — `volatile-lru` only has something to evict if the cache is allowed to be evicted.
