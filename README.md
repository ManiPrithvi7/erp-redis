# proof-erpnext-redis

One Bitnami Redis, one Render private service, one `$7`/month plan — serving **both** of
Frappe's Redis needs by logical database index:

| URL in `common_site_config.json` | db | what lives there | on eviction |
|---|---|---|---|
| `redis_cache` | `/1` | Frappe's rendered fragments, sessions, user settings | may be evicted, that is the point |
| `redis_queue` | `/2` | RQ job lists, scheduler ZSET, job payloads | must never be evicted |
| `redis_socketio` | `/2` | unused (no socketio in this scope) | — |

This is one of three sibling repos that together replace the single
`erp/docker-compose.minimal.yml` of the parent project with independently deployed Render
services: [`proof-erpnext-db`](../proof-erpnext-db), this one, and
[`proof-erpnext-app`](../proof-erpnext-app). Findings for the whole stack live in
[proof-erpnext-app/LIMITATIONS.md](../proof-erpnext-app/LIMITATIONS.md).

## Why one instance is safe here, and was not on Upstash

The old compose file used two **separate** Upstash databases and its README warned that
`bench clear-cache` flushes keys. Both objections are artefacts of a managed Redis that
refuses `SELECT`, not of Frappe:

- `frappe/utils/redis_wrapper.py` builds the cache client with `RedisWrapper.from_url(frappe.conf.redis_cache)`
  and `frappe/utils/redis_queue.py` with `redis.from_url(frappe.conf.redis_queue)` — both take a
  full URL, so the `/N` suffix is honoured and one host can serve both.
- `bench clear-cache` → `frappe.clear_cache()` → key-scoped `delete_keys`/`get_keys` (SCAN + DEL)
  on the cache connection only. Grepping the whole Frappe tree for `flushall` finds it **only in
  tests**. Clearing the cache cannot wipe db 2, where the jobs are.

Verified against `frappe/erpnext:v16.9.1`. The two residual risks are experiments rather than
assumptions: `X14` (a queued job survives `bench clear-cache`) runs in
`proof-erpnext-app/scripts/persistence-check.sh --stage clear-cache`, and `X15` (cache pressure
starving the queue under one shared `maxmemory`) runs here in `scripts/x15-maxmemory.sh`.

One global `maxmemory-policy` is the price of one instance, which is why the image ships
`--maxmemory 200mb --maxmemory-policy volatile-lru`: only keys carrying a TTL are eviction
candidates, and RQ's job keys have no TTL so they are never evicted. X15 measured the other half
of that sentence, and it is worth reading before changing the policy: most of Frappe's own cache
keys have no TTL either, so on this instance there is very little the policy *can* evict —
maxmemory has to be sized as headroom, not as a limit to lean on.

## Local

```bash
cp .env.example .env          # optional; compose defaults are working credentials
docker compose up -d
./scripts/persist-check.sh    # 10 assertions: identity, config, AOF, db1+db2 markers,
                              # planned restart, then kill -9 + AOF replay
./scripts/x6-repro.sh         # the failure this image exists to prevent, both sides
./scripts/x15-maxmemory.sh    # cache vs queue under one maxmemory, three cases
```

`persist-check.sh` currently reports **10 passed, 0 failed** on this machine; `x6-repro.sh` runs
Bitnami's stock image and this image against the same unwritable `root:root` volume and shows the
stock one dying on its own append-only file.

## Files

| path | what it is |
|---|---|
| `Dockerfile` | the pinned digest, the `redis`→uid 1001 passwd entry, `USER root`, the two `REDIS_*` env defaults |
| `docker/entrypoint.sh` | recursive `chown` of the mounted disk, then `exec "$@"` so Bitnami still drops to uid 1001 itself |
| `render.yaml` | `pserv`, `starter`, 5 GB disk at `/bitnami/redis/data`, port 10000 |
| `scripts/persist-check.sh` | does it actually persist |
| `scripts/x6-repro.sh` | the root-owned-disk trap, reproduced for $0 |
| `scripts/x15-maxmemory.sh` | what one shared `maxmemory` does to the queue when the cache cannot be evicted |
| `RENDER_DEPLOY.md` | deploy order, the Bitnami supply-chain table, the re-pin procedure, verification one-liners |

## Read next

- [RENDER_DEPLOY.md](RENDER_DEPLOY.md) — what to click, which URL to copy into the app service,
  and why `bitnamilegacy` is a frozen image on purpose.
