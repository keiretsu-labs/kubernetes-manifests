# Personalized `home.keiretsu.top` — Architecture & Implementation

## Summary
Replace the multi-cluster GSLB Homer dashboard at `home.keiretsu.top` with a
lightweight Python stdlib app that shows **each logged-in user only their apps**.

## Architecture

```
Browser                    Cloudflare                Envoy Gateway (ottawa)
   │                          │                           │
   │  home.keiretsu.top       │                           │
   │─────────────────────────>│                           │
   │  (proxied)               │  CNAME home.cdn.keiretsu  │
   │                          │──────────────────────────>│
   │                          │                           │
   │                          │              ┌────────────┴────────────┐
   │                          │              │  SecurityPolicy:       │
   │                          │              │  homepage-tinyauth     │
   │                          │              │  extAuth → tinyauth    │
   │                          │              │  authZ  → Remote-Email │
   │                          │              └────────────┬────────────┘
   │                          │                           │
   │                          │              ┌────────────┴────────────┐
   │                          │              │  tinyauth (Google OAuth)│
   │                          │              └────────────┬────────────┘
   │                          │                           │
   │                          │              ┌────────────┴────────────┐
   │                          │              │  HTTPRoute: homepage   │
   │                          │              │  host: home.keiretsu   │
   │                          │              │  → Service: homepage   │
   │                          │              └────────────┬────────────┘
   │                          │                           │
   │                          │              ┌────────────┴────────────┐
   │                          │              │  Homepage Pod (2x)      │
   │                          │              │  python:3.13-alpine     │
   │                          │              │                         │
   │                          │              │  Reads:                 │
   │                          │              │  Remote-Email header    │
   │                          │              │  ↓                      │
   │                          │              │  K8s API (SA)           │
   │                          │              │  → list SecurityPolicies│
   │                          │              │  → match email          │
   │                          │              │  → resolve HTTPRoutes   │
   │                          │              │  → render dashboard     │
   │                          │              └─────────────────────────┘
```

## Auth Flow

| Step | Component | What happens |
|------|-----------|-------------|
| 1 | Browser → Envoy | GET `home.keiretsu.top/` |
| 2 | SecurityPolicy | triggers extAuth → tinyauth |
| 3 | tinyauth | Google OAuth flow (redirect + callback) |
| 4 | tinyauth → Envoy | injects `Remote-Email`, `Remote-Name` headers |
| 5 | SecurityPolicy authZ | checks `Remote-Email` against allow-rules |
| 6 | Allowed? | → homepage pod (with headers) |
| 7 | Denied? | → 403 from Envoy |

## App Discovery Algorithm

```
discover_user_apps(email):
  1. GET /apis/gateway.envoyproxy.io/v1alpha1/securitypolicies
  2. Filter: rules[action=Allow].principal.headers[name=Remote-Email].values → match email
  3. For each matching SecurityPolicy:
     a. Resolve targetRefs → HTTPRoute name
     b. GET /apis/gateway.networking.k8s.io/v1/namespaces/{ns}/httproutes/{name}
     c. Read Homer annotations (item.homer.rajsingh.info/*)
     d. Read service group annotations (service.homer.rajsingh.info/name)
     e. Fallback: derive group from gateway name (public/private/ts)
  4. Group apps by service.homer.rajsingh.info/name
  5. Cache result for 300s (stale cache served if K8s API unavailable)
```

## Resource Manifest (final)

### `kubernetes/apps/base/home/home/homepage/` (9 files)

| File | Type | Key detail |
|------|------|-----------|
| `server.py` | Python HTTP server | stdlib-only K8s API client, 334 lines |
| `style.css` | Dark theme CSS | matches Keiretsu design system |
| `deployment.yaml` | Deployment | 2 replicas, python:3.13-alpine, ConfigMap mounts |
| `service.yaml` | Service | ClusterIP port 80 → 8080 |
| `httproute.yaml` | HTTPRoute | hostname `home.keiretsu.top`, public + private gateways |
| `securitypolicy.yaml` | SecurityPolicy | extAuth → tinyauth, authZ by Remote-Email |
| `serviceaccount.yaml` | ServiceAccount | `homepage` SA for K8s API queries |
| `rbac.yaml` | ClusterRole+Binding | list/get SecurityPolicies + HTTPRoutes |
| `kustomization.yaml` | Kustomization | wires all resources + ConfigMapGenerator |

### Modified files (2)

| File | Change |
|------|--------|
| `k8gb/k8gb-common/config/gslb-dashboard-cdn.yaml` | Remove `home.${COMMON_DOMAIN}` from HTTPRoute hostnames |
| `auth/tinyauth/referencegrant.yaml` | Allow `home` namespace SecurityPolicies to reference tinyauth |

### Cluster Flux configs (3 files, identical)

Each cluster's `{cluster}/home/home.yaml` adds a `home-homepage` Flux Kustomization:
- Path: `./kubernetes/apps/base/home/home/homepage`
- Depends on: `envoy-gateway-system-install` + `home-homer`

## Key Design Decisions

1. **stdlib-only Python** — no `kubernetes` client, no pip. Uses `urllib.request`
   + service account token at `/var/run/secrets/kubernetes.io/serviceaccount/token`.

2. **Probe safety** — probes hit `/` without `Remote-Email`. Handler returns empty
   page (no caching) when email is empty. Prevents probe cache pollution.

3. **Stale cache on failure** — if K8s API is unreachable, stale discovery results
   are served (up to 5 min). No cache = error message shown.

4. **DNS CNAME unchanged** — `home.keiretsu.top → home.cdn.keiretsu.top` remains.
   CNAME resolves to GSLB endpoint → cluster gateway → matches `home.keiretsu.top`
   on the `homepage` HTTPRoute.

5. **Homer retained on CDN** — `home.cdn.keiretsu.top` still serves Homer dashboard
   for CDN-optimized use. Only `home.keiretsu.top` moved to the Python app.

## Zero-Config User Maintenance

Adding a new user:
```
1. Add email to TINYAUTH_OAUTH_WHITELIST in tinyauth.env
2. Allow email in each SecurityPolicy they should access
3. Done — homepage auto-discovers their apps on next visit
```

No need to touch any homepage config, no `users.json`, no redeploy.

## Verification

- [x] `home.keiretsu.top` → Google login → personalized dashboard
- [x] `home.cdn.keiretsu.top` → Homer dashboard (unchanged)
- [x] Unauthorized email → 403
- [x] Probes don't pollute cache (empty email → 0 groups)
- [x] K8s API cache refreshes every 5 minutes
- [x] All 3 clusters have Flux Kustomization for homepage