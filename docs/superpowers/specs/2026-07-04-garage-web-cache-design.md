# Garage Web Cache — in-cluster CDN layer for static sites

**Date:** 2026-07-04
**Status:** Design approved, pending spec review

## Problem

Static sites are served straight from Garage's built-in web endpoint
(`garage-gateway:3902`). There is no byte cache anywhere — the only caching is a
`Cache-Control` response header the HTTPRoute injects (browser-side only).

Every uncached object GET therefore pays the Garage origin cost: gateway pods
use EmptyDir (no local object cache), and with replication factor 3 in
`consistent` mode a cold read needs a **quorum read that can span clusters over
Tailscale RPC**. First-byte latency is a cross-region round trip on every miss.

Example chain today (`trades.rajsingh.info`):
`browser → Envoy public gateway → HTTPRoute (URLRewrite Host→bucket, adds
Cache-Control: max-age=3600) → garage-gateway:3902 → Garage quorum read`.

Cloudflare edge proxying was explicitly ruled out — the fix must live in the
cluster.

## Goals

- Eliminate the repeated Garage quorum-read cost for hot objects (snappy).
- Low, bounded RAM footprint regardless of cached content size.
- Bucket content changes propagate to visitors **fast** (target: edge reflects
  within ~10s, browsers within ~60s) without hammering the origin.
- Low touch: no new Flux Kustomization, no per-site cache config, no changes to
  the site-deploy pipeline.

## Non-goals

- Geographic edge / global anycast (that was the Cloudflare option; declined).
  Geographic spread is already handled by the three clusters + k8gb GSLB.
- Fronting the S3 API (`httproute-s3.yaml`) — API traffic is not cacheable here.
- Cache purge-on-deploy — noted as an optional future upgrade, not in scope.

## Architecture

Insert one shared caching reverse proxy between the Envoy `public` gateway and
`garage-gateway:3902`. Nothing else in the request chain changes:

```
Envoy public gateway  (URLRewrite Host→<bucket>.${COMMON_DOMAIN}, existing)
  → garage-web-cache Service :80   (nginx proxy_cache)   ← cache HIT ends here
      → garage-gateway :3902        (only on MISS / revalidate)
          → Garage quorum read
```

- **One shared `garage-web-cache`** Deployment + Service in the `garage`
  namespace, deployed to all three clusters (it lives in `base/garage/garage/`,
  which every location pointer already reconciles).
- Shared across every site: nginx keys the cache on **`Host + URI`**, and the
  gateway has already rewritten `Host` to `<bucket>.${COMMON_DOMAIN}`, so each
  bucket/site is naturally isolated in one cache. **Adding a site needs zero
  cache changes.**
- Combined with the existing k8gb GSLB (which routes a visitor to the nearest
  healthy cluster), a per-cluster cache yields a genuine self-hosted 3-PoP CDN.

## Component: `garage-web-cache`

A minimal nginx reverse-proxy cache. Files added to
`kubernetes/apps/base/garage/garage/` and listed in that `kustomization.yaml`.

**Deployment**
- Image: stock `nginx` (unprivileged variant; runs as non-root).
- Replicas: 2 for HA. Caches are independent per replica; they warm on their
  own — acceptable for small static sites.
- Cache volume: **plain `emptyDir` (node disk, not `medium: Memory`)**. Bodies
  live on disk; Linux page-cache keeps hot ones fast.
- Resources: request ~16Mi memory / small CPU; limit ~64Mi. RAM is dominated by
  the nginx key index, not the cached bytes.

**nginx cache behaviour (the smart part)**
- `proxy_cache_path ... keys_zone=web:5m max_size=<bounded, e.g. 2g>
  inactive=1h` — the **5m keys_zone indexes ~40k objects in ~5 MB of RAM**; body
  count is bounded by disk (`max_size`) and evicted after `inactive`.
- `proxy_cache_key "$host$request_uri"` — per-bucket, per-path isolation.
- `proxy_cache_revalidate on` — on expiry, send a conditional request
  (`If-None-Match`/`If-Modified-Since`) using Garage's `ETag`/`Last-Modified`.
  Unchanged objects return **304 with no body** — a cheap metadata check, not a
  full quorum data read. Changed objects are refetched.
- `proxy_cache_valid 200 10s` — short edge TTL, so a bucket change is reflected
  within ~10s; unchanged objects cost only a 304 per interval.
- `proxy_cache_lock on` — collapse a burst of concurrent misses for the same
  object into a single origin fetch (no thundering herd on Garage).
- `proxy_cache_use_stale error timeout updating http_500 http_502 http_503` +
  `proxy_cache_background_update on` — serve the cached copy instantly while
  revalidating in the background, and keep serving during a Garage hiccup or
  rebalance. Stale served is at most one short TTL old.
- `proxy_set_header Host $host` — forward the rewritten bucket host to Garage.
- Pass through / normalize `Cache-Control`, `ETag`, `Last-Modified`.

**Config rollout:** the nginx config is a ConfigMap whose changes must roll the
Deployment (name-suffix hash or equivalent), so a config edit reliably restarts
pods. (Mechanism decided in the plan; the base `kustomization.yaml` currently
sets `disableNameSuffixHash: true` globally — the cache config generator must
opt out of that.)

## Freshness — the browser-side gotcha

The edge cache alone is not enough. The fronted HTTPRoutes inject
`Cache-Control: public, max-age=3600`, which is the **browser's** TTL — a
visitor would pin old content for an hour after a bucket update, and the edge
cache cannot purge a browser.

**Change the client-facing header on the fronted routes to
`public, max-age=60, stale-while-revalidate=30`.** Browsers recheck within ~60s
(and nginx answers those rechecks cheaply from disk). Tune toward 0 for faster
propagation, up for less origin chatter. This is a value edit to the existing
`ResponseHeaderModifier` — no new mechanism.

## Integration / wiring changes

1. **New files** in `kubernetes/apps/base/garage/garage/`:
   `web-cache.yaml` (Deployment + Service) + nginx ConfigMap; add to
   `kustomization.yaml`. Deploys everywhere Garage does.
2. **`kubernetes/components/cdn-site/httproute.yaml`**: `backendRefs` flips
   `garage-gateway:3902` → `garage-web-cache:80`; `Cache-Control` value lowered
   as above. Covers `trades` and every future cdn-site.
3. **`kubernetes/apps/base/garage/garage/httproute-web.yaml`** (public
   `keiretsu.top` / `www` root site): same backendRef + Cache-Control change.
4. **Out of scope / optional**: the OIDC-gated agent web routes
   (`assistant-raj`, `teaspoon`) — low traffic, flip later if wanted.

Both backends are ClusterIP Services in the `garage` namespace, so swapping one
for the other needs **no new ReferenceGrant**.

## Multi-cluster behaviour

- `keiretsu.top` GSLB-fronted sites (e.g. `keiretsu.cdn.keiretsu.top`) get
  multi-PoP caching automatically — each cluster's cache serves its region.
- `trades.rajsingh.info` gets **Ottawa-local** caching today, because the
  `rajsingh.info` external-dns runs `--force-default-targets=${LOCATION}.rajsingh.info`
  and pins the host to Ottawa (the GSLB path is dormant for `rajsingh.info`).
  Still fixes the dominant origin-latency cost for that site.

## Validation plan

- Confirm Garage v2 web endpoint honours conditional GET and returns
  `304 Not Modified` for `If-None-Match` with the current `ETag` (drives the
  revalidate design; verify against a live bucket during implementation).
- `make test` render of all three clusters.
- Live check on one cluster: first GET populates the cache (`X-Cache-Status:
  MISS`), second is `HIT`; update the object, confirm the change is visible
  within ~10s at the edge; confirm response `Cache-Control` reflects the new
  browser TTL.
- Confirm cache pod RAM stays flat (tens of MB) while cached content grows.

## Rejected alternatives

- **Cloudflare orange-cloud edge** — best geographic fix and lowest infra, but
  the user requires an in-cluster solution.
- **tmpfs (`emptyDir medium: Memory`) cache** — RAM-speed but consumes RAM
  proportional to cached content; conflicts with the low-RAM goal. Disk emptyDir
  + page-cache is nearly as fast with a bounded, tiny RAM footprint.
- **Long TTL + purge-on-deploy** — instant propagation, but requires a call from
  the site-deploy pipeline (more touch). Kept as a future upgrade on top of this.
- **Envoy Gateway native HTTP cache filter** — no extra pod, but the filter is
  experimental and only reachable via a brittle `EnvoyPatchPolicy` that breaks
  across Envoy Gateway upgrades. nginx is boring and durable.

## Future upgrades (not in scope)

- Purge-on-deploy hook for instant propagation with long TTLs.
- Fronting `rajsingh.info` sites via the GSLB (needs the CRD-source external-dns
  / DNSEndpoint pattern) to make them multi-PoP like the `keiretsu.top` sites.
