# EnvoyGateway SecurityPolicy extAuth: body-size / timeout posture

Census date: 2026-10-21. **Git-metadata audit of the manifests in this
repository, plus one live read-only Ottawa cross-check** (no mutation; the
tinyauth namespace exists on Ottawa only). Scope: every repo-tracked
`kind: SecurityPolicy` with an `extAuth` block, every
`BackendTrafficPolicy`/`ClientTrafficPolicy` body/timeout knob, and the ADR
0009 coupling context. Companion to the 10-19 timeout/retry census
(status §2026-10-19; zot-public retry, plex/webtop streaming, bhaiya limits)
— that pass covered *backend* timeouts; this one covers the *extAuth filter*
plane and per-route body limits, and reconciles both against ADR 0009.

**Population note.** Live Ottawa serves 69 SecurityPolicies: 19 Flux-managed
from this repo + 50 bhaiya-controller-generated (`app.kubernetes.io/
managed-by: bhaiya` — per-workspace `secpol-*` families and v2-control
policies; 49 of the 69 carry `extAuth`). This census covers **only the 14
repo-tracked extAuth policies**; controller-generated ones are owned by
bhaiya's own GitOps and are excluded here (their shape is
workspace-scoped allowlists, same tinyauth backend — no body/timeout knobs
observed on the live set either, but that is bhaiya-repo territory).

## repo-tracked extAuth census — 14 policies, one shape

| # | SecurityPolicy | target HTTPRoute(s) | failOpen | extAuth svc | body/timeout knobs in policy |
|---|---|---|---|---|---|
| 1 | cliproxy-ui-tinyauth | cliproxy-ui | false | tinyauth:3000 | none |
| 2 | firefly-tinyauth | firefly | false | tinyauth:3000 | none |
| 3 | garage-webui-tinyauth | garage-webui | false | tinyauth-killinit:3000 | none |
| 4 | frigate-tinyauth | frigate | (unset=default) | tinyauth:3000 | none |
| 5 | homepage-tinyauth | homepage | (unset) | tinyauth:3000 | none |
| 6 | bhaiya-tinyauth | bhaiya-cdn, bhaiya-cdn-plain | (unset) | tinyauth:3000 | none |
| 7 | hubble-tinyauth | hubble-cdn | (unset) | tinyauth:3000 | none |
| 8 | opencost-tinyauth | opencost-cdn | (unset) | tinyauth:3000 | none |
| 9 | grafana-cdn auth | grafana-cdn | (unset) | tinyauth:3000 | none |
| 10 | victoria-logs-cdn auth | victoria-logs-cdn | (unset) | tinyauth:3000 | none |
| 11 | prometheus-cdn auth | prometheus-cdn | (unset) | tinyauth:3000 | none |
| 12 | suwayomi | suwayomi | (unset) | tinyauth:3000 | none |
| 13 | teslamate | teslamate | false | tinyauth:3000 | none |
| 14 | woodpecker | woodpecker | false | tinyauth:3000 | none |

Uniform contract on all 14: `headersToExtAuth [cookie, x-forwarded-proto,
x-forwarded-for, user-agent]`, `path /api/auth/envoy?path=`,
`headersToBackend [remote-user, remote-email, remote-name, remote-groups]`,
authZ via `authorization.defaultAction: Deny` + Remote-Email allowlists
(bhaiya delegates authZ in-process instead — documented in-file).

## Finding E1 — no extAuth body-size / timeout knobs exist anywhere (by design, LOW)

Scripted walk of every SecurityPolicy/BackendTrafficPolicy/ClientTrafficPolicy
in the repo: **zero `extAuth.http.timeout`, zero `extAuth.bodySize` /
`maxRequestBytes`, zero per-route body-limit settings on any extAuth route.**
The only body-limit in the fleet is `bhaiya-plain-http-limits.requestBuffer
8Mi` (gslb-bhaiya.yaml, documented vs Bhaiya's 4MiB chunk upload) — a
BackendTrafficPolicy on the *plain* lane, not an extAuth knob.

Consequences, assessed:

- **extAuth request path inherits chart defaults** (no override; body
  forwarded per `headersToExtAuth`, no body buffering override). All 14 policies target browser/UI routes whose
  payloads are cookies+headers only; none proxies large uploads *through*
  the extAuth check differently from the backend path. The default timeout
  applies against `tinyauth` (same-cluster Service, sub-ms RTT) — both
  tinyauth and tinyauth-killinit Deployments are `replicas: 1`
  (deployment.yaml:6 each) and no PodDisruptionBudget exists for them in
  any manifest (repo-wide grep; the 10-19 PDB census found singletons
  deliberately PDB-less so drains stay unblocked). A
  node drain therefore briefly removes the extAuth path entirely — an
  accepted property of the singleton design, not a timeout problem.
- **No drift**: the 5 explicit `failOpen: false` vs 9 unset is the only variance and
  it is *safer* on the explicit side (failOpen default is false in EG; the
  unset majority is default-identical, verified against chart v1.9.2
  defaults). One knob, one value class — nothing to reconcile.

## Finding E2 — per-route limit asymmetry is deliberate, matches the 10-19 census (INFO)

Streaming/long-held routes (plex, webtop, zot-public, bhaiya CDN streams)
carry explicit `timeout` overrides (`0s = unlimited`) precisely *because*
defaults would tear down streams; CRUD/limit-bearing routes (bhaiya-plain)
carry `requestBuffer`+`rateLimit`. Every extAuth route is in the
browser-CRUD class → correctly knob-free. The asymmetry is the design, not
drift: routes that need limits have them, routes that would be hurt by them
don't.

## ADR 0009 cross-check — no coupling, no drift

ADR 0009's mechanism is the **extensionManager xDS hook** (Agent Router),
removed 2026-09-24; its failure mode was translation-freeze, not per-route
policy behavior. The extAuth plane here uses only first-class EG CRDs
(SecurityPolicy / EnvoyExtensionPolicy-Lua / BackendTrafficPolicy) which
translate in the core envoygateway controller — **no extensionManager
participation**, so none of ADR 0009's includeAll blast radius applies.
Verified: `envoy-gw-common/install/helmrelease.yaml` still carries the
"No extensionManager here on purpose" block (comment intact post-#3179
removal, present at d4b214504); `extensionApis.enableLua` remains (required
by the 401→302 Lua redirect hooks on firefly/bhaiya/frigate/garage-webui/
cliproxy — the tinyauth challenge conversion), which is a *extensionApi*
flag, not an extensionManager hook. No drift between ADR text and manifest
state.

## Residuals (recorded, not actioned)

- R1: tinyauth itself (ghcr.io/tinyauthapp/tinyauth:v5.2.0) exposes no
  request body/timeout env knobs in its deployment; a pathological tinyauth
  hang would surface as extAuth 500/503 with `failOpen:false` = hard gate on
  the 5 explicit-false routes (cliproxy/firefly/garage-webui/teslamate/
  woodpecker) — and effectively on all 14, since unset also means
  fail-on-error. Mitigation would be an extAuth `timeout` override — only
  worth adding if observed; no source-verified 504 pattern is on record here
  (git-metadata audit; no log claim made).
- R2: 9 of 14 policies (rows 4–12) could state `failOpen: false` explicitly
  for grep-ability; cosmetic.

## Verdict

**NO-FINDING requiring change.** The repo-tracked extAuth plane is knob-free
by coherence: uniform 14-policy shape, defaults correct for the browser-CRUD traffic
class, the single body limit fleet-wide (bhaiya 8Mi) is where uploads
actually flow, and ADR 0009's extensionManager risk does not intersect the
SecurityPolicy path. No PR; census recorded here.
