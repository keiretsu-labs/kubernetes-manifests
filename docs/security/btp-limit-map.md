# BackendTrafficPolicy: rate-limit / circuit-breaker usage map

Census date: 2026-10-21. Git-metadata + one live read-only cross-check
(route counts; no mutation). Question: which HTTPRoutes carry rate limits or
circuit breakers, and which public routes have none. Complements the
timeout/retry census (10-19) — that pass covered timeouts; this one covers
the *protection* knobs only.

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

Universe for this section: the repo-tracked public-parented HTTPRoutes
(namespace `bhaiya` excluded — those routes are controller-generated and
counted in the bhaiya census). Within it:

- **Public-parented HTTPRoutes**: 45 distinct routes in the repo-tracked set
  (43 names rendered live across the three clusters; multi-site routes render
  per cluster, plus the `${SITE}-cdn` component template).
- **With a SecurityPolicy (tinyauth extAuth): 15 route bindings from the 14
  policies** in the extauth census — one policy (`bhaiya-tinyauth`) binds two
  routes (`bhaiya-cdn`, `bhaiya-cdn-plain`), hence 15 bindings ≠ 14 policies.
- **With any BTP: 5 routes** — `bhaiya-cdn-plain` (rate limit), `zot-public`
  (retry/health), and `plex`/`webtop`/`proxyt` upgrade-timeout BTPs. Of these,
  4 are *not* SP-covered (`zot-public`, `plex`, `webtop`, `proxyt`) and
  `bhaiya-cdn-plain` is counted in the SP set above.
- **Neither SP nor BTP — 28 routes** across the fleet (distinct names;
  multi-site routes counted once), listed below with their story:

| route | protection story |
|---|---|
| `grafana-redirect` ×2, `grafana-http-redirect` | pure RequestRedirect filters — no backend to protect |
| `dashboard-cdn`, `dashboard-public` (homer) | intentional public read-only dashboard |
| `gatus`, `gatus-cdn`, `gatus-status` | intentional public status page (documented route-exposure-inventory.md:31) |
| `kromgo` | intentional badges-only |
| `immich-server` (rb) | Immich app login / API keys |
| `tsflow-public` | tailnet identity upstream + local 403 poller-refresh |
| `forgejo-cdn` | Forgejo app auth (public code hosting by design) |
| `garage-web`, `garage-web-cdn`, `garage-s3-cdn` | S3 sigv4 / public website content |
| `audiobookshelf`, `bookorbit`, `bookorbit-devices`, `komga`, `overseerr`, `tautulli`, `wizarr`, `homeassistant` (sp) | app-native login (per route-exposure-inventory media audit) |
| `bhaiya-cdn-v2-api` | header-match bearer token in route spec (in-file documented; app verifies) |
| `bhaiya-cdn-cli-public` | deliberate public installer/catalog path |
| `tinyauth`, `tinyauth-killinit` | the auth service itself — its login page must be reachable |
| `woodpecker-api` | Woodpecker agent/API lane, token-authenticated by the server |
| `forgejo` (forgejo ns) | Forgejo app auth, direct name |

CDN-fronted aliases (`*-cdn`) inherit whatever their backend route carries;
the table above lists the origin protection.

## Findings

**F1 — single rate-limit object; asymmetry is deliberate (INFO).** The only
admission control in the fleet guards the plain browser lane, where the
in-file comment records the sizing math. Every other public route relies on
app auth or is intentionally open. No circuit breaker is tuned anywhere; EG
defaults stand.

**F2 — the no-policy set has an identified story for every entry (no-finding
on exposure); 2 hardening candidates tracked internally if limits are ever
wanted (recorded, not actioned):** one on the public object-storage front
(the sigv4 auth layer already gates it; a local rateLimit would only dampen
noise) and one on the token-authenticated API front (per-request verify, no
admission cap). Neither is a defect; the 10-19 pass found no overload
evidence.

**F3 — redirect-only routes carry no policy by construction** (no backend ⇒
nothing to protect); listed once here so future sweeps can exclude them
mechanically.

## Verdict

**NO-FINDING requiring change.** One rate limit, zero circuit breakers, and
every public route without a policy has a documented protection story or is
redirect-only. The two hardening candidates are tracked internally above; no
PR in this docs-only item.
