# BackendTLS / upstream-TLS verification census

Scope: git-metadata audit of `kubernetes/` + `clusters/` on `main` (ba8c61979), plus read-only cross-checks of Probe/HTTPRoute objects on all three clusters. No mutation; no chart/runtime change. Companion to `route-exposure-inventory.md` (client-facing TLS) — this is the *backend* leg.

## Policy

Upstream TLS verification fleet-wide uses **system trust or a pinned CA**; private-CA exceptions are tracked in the internal registry and reviewed on rotation. Public endpoints are verified end-to-end; no upstream skip applies to a publicly-routed name. The internal-CA issuer (`certificate-expiry-surface.md`) signs gateway listener certs only.

## 1. BackendTLSPolicy objects: zero

`kind: BackendTLSPolicy` — **0 hits repo-wide** (all API versions). No Gateway-API route in the fleet requests `https` scheme against a backend Service, and no BackendTLSPolicy exists to verify one. No `EnvoyProxy` CR sets `backendTLS` or upstream mTLS, and no serverSide service mesh is enabled — nothing to verify, so absence is coherent, not a gap. Per-backend TLS posture is therefore governed by the policy above, not per-route CRs.

## Findings

- **B1 (Info)**: the blackbox `http_2xx_insecure` module has zero consumers — dead config; fold its removal into the next blackbox-touching change (not worth a solo PR).
- **B2 (no-finding)**: no BackendTLSPolicy, no https backends, no upstream mTLS — nothing further to census; the internal PKI surface is gateway-listener-only by design.

Verdict: **no-finding** — upstream verification is system-trust/pinned-CA by policy with tracked private-CA exceptions; no gap to remediate. No PR.

Backlog line 119 [x] no-finding.
