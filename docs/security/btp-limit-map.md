# BackendTrafficPolicy: rate-limit / circuit-breaker usage map

Census date: 2026-10-21. Git-metadata + live read-only. Question: which
HTTPRoutes carry rate limits or circuit breakers, and which public routes have
none. Complements the timeout/retry census (10-19) — that pass covered
timeouts; this one covers the *protection* knobs only.

## BTP inventory — 6 objects, 1 with limits

| BTP | Target route | rateLimit | circuitBreaker | other knobs |
|---|---|---|---|---|
| `bhaiya-plain-http-limits` | bhaiya-cdn-plain (keiretsu-top) | **yes** — local 600/min per Envoy instance, admission-charged | – | requestBuffer 8Mi |
| `zot-public-timeouts` | zot-public | – | – | timeouts + retry×3 + passive outlier detection (health-ish, not CB) |
| `plex-upgrade-policy` | plex | – | – | websocket upgrade, bufferLimit, streaming timeouts |
| `webtop-upgrade-policy` | webtop | – | – | websocket upgrade, bufferLimit, streaming timeouts |
| `proxyt-upgrade-policy` | proxyt | – | – | websocket/control-protocol upgrade only |
| (ClientTrafficPolicy ×2) | gateways public/private/ts | – | – | http2 windows, timeouts — connection hygiene, not limits |

**Exactly one rateLimit and zero circuitBreakers fleet-wide.** EG
circuit-breaker defaults apply implicitly everywhere (per-CD priority, max
connections/requests/pending/retries chart defaults, v1.9.2) — none tuned
anywhere, none observed exhausted (no 503/overflow patterns on record).

## Protected vs unprotected public routes

Public-parented HTTPRoutes: 53. With a SecurityPolicy (tinyauth extAuth): 15
(see extauth census). With any BTP: 3 (bhaiya-cdn-plain limits; webtop,
plex, proxyt = upgrade/timeout only — no admission control). **Neither SP nor
limits — 13 routes:**

| route | auth story | limit story |
|---|---|---|
| `grafana-redirect`, `grafana-http-redirect` ×2 sites | pure RequestRedirect filters | n/a — no backend |
| `dashboard-cdn`, `dashboard-public` (homer) | none — public read-only dashboard (per homer route family) | none |
| `gatus`, `gatus-cdn`, `gatus-status` | none — intentional public status page (documented route-exposure-inventory.md:31) | none |
| `kromgo` | none — intentional badges-only | none |
| `plex` | Plex login (app auth) | none (streaming timeouts only) |
| `immich-server` (rb) | Immich app login / API keys | none |
| `tsflow-public` | tailnet identity upstream + 403 poller-refresh local | none |
| `forgejo-cdn` | Forgejo app auth (public code hosting by design) | none |
| `garage-web-cdn` | S3 sigv4 / public website content | none |
| `bhaiya-cdn-v2-api` | header-match `Authorization: Bearer bht_*` in route spec (in-file documented; app verifies) | none |
| `bhaiya-cdn-cli-public` | none — deliberate public installer/catalog (`/install.sh`,`/dl`,`/skills`) | none |
| `bhaiya-cdn` browser lanes | tinyauth SP (listed for completeness) | none |

CDN-fronted aliases (`*-cdn`) inherit whatever their backend route carries;
the table above lists the origin protection.

## Findings

**F1 — single rate-limit object; asymmetry is deliberate (INFO).** The only
admission control in the fleet guards bhaiya-plain, where the in-file comment
records the sizing math (4MiB chunks, browser burst). Every other public
route relies on app auth or is intentionally open. No circuit breaker is
tuned anywhere; EG defaults stand.

**F2 — unprotected set is 13 routes, all with an identified story (no-finding
on exposure); 2 candidates if limits are ever wanted (recorded, not
actioned):** `garage-web-cdn`/`garage-s3` family (public S3 endpoint —
sigv4 already throttles abuse at the auth layer, but a cheap local
rateLimit would cap bucket-brute noise) and `bhaiya-cdn-v2-api` (bearer
gate is per-request verify, no admission cap — a flood costs CPU before
401s). Neither is a defect; the 10-19 pass found no overload evidence.

**F3 — redirect-only routes carry no policy by construction** (no backend ⇒
nothing to protect); listed once here so future sweeps can exclude them
mechanically.

## Verdict

**NO-FINDING requiring change.** One rate limit, zero circuit breakers, and
every unprotected public route has a documented auth story or is
redirect-only. Candidates (garage-s3, bhaiya-v2-api) recorded for a future
hardening pass; no PR in this docs-only item.
