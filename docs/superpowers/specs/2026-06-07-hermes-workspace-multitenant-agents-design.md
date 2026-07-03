# hermes-workspace multi-tenant agents — design

date: 2026-06-07
status: approved (design), pending implementation plan
scope: `clusters/${CLUSTER_NAME}/apps/agents` (talos-ottawa today)

## goal

Add a new *form* of agent to the `agents` namespace: a group-served Hermes
deployment whose primary entry point is the **public** `*.agents.${COMMON_DOMAIN}`
Gateway with **Pocket ID OIDC** at the edge — not a Tailscale `tag:` LoadBalancer.

Each tenant is a **group**. Groups vary in size: some are a single person, some
are several users sharing one backend. The system must scale to many groups with
"add a group = a tiny overlay", and isolate groups hard from one another.

The existing five single-user Tailscale agents (`assistant-raj`, `abtar`,
`kartik`, `teaspoon`, `camofox`) stay exactly as they are. This is an additive
second template, not a migration.

## terminology

- **group / tenant** — the unit of isolation. One Hermes instance, one PVC, one
  subdomain, one Pocket ID client. A single-person group is just a group of one.
- **member** — a user authorized into a group (a Pocket ID user in the group's
  allowed user-group).

## why instance-per-group (not user-per-instance)

Hermes' isolation unit is the *instance*, not the user. There is no in-instance
RBAC today (the admin/user tier-split is draft RFC NousResearch/hermes-agent#20744,
unshipped). Anyone holding a gateway's `API_SERVER_KEY` gets the full toolset
including a terminal. Therefore:

- **between groups** → separate instance + PVC + Pocket ID client. Hard isolation.
- **within a group** → shared instance is acceptable (members trust each other);
  per-user memory is scoped softly via `X-Hermes-Session-Key` (phase 2).

## architecture

```
user ─► https://<group>.agents.${COMMON_DOMAIN}
   │
   ▼
public Gateway  (home/public, Envoy Gateway)
   listener: *.agents.${COMMON_DOMAIN}  (HTTPS, wildcard cert)   ← NEW
   │
   ▼
HTTPRoute(<group>)  ──targetRef──►  SecurityPolicy.oidc
   hostname <group>.agents.${COMMON_DOMAIN}     issuer  pocket-id.${COMMON_DOMAIN}
   backend  Service(<group>) :3000              clientID/secret  per-group
   │
   ▼
Service(<group>)  ClusterIP  :3000 workspace · :8642 gateway · :9119 dashboard
   │
   ▼
Pod(<group>)
   ├─ container: workspace   ghcr.io/outsourc-e/hermes-workspace  :3000
   │     HERMES_API_URL=http://127.0.0.1:8642
   │     HERMES_DASHBOARD_URL=http://127.0.0.1:9119
   │     HERMES_API_TOKEN=<group API_SERVER_KEY>
   ├─ container: gateway     nousresearch/hermes-agent  :8642/:9119
   └─ PVC(<group>)  ceph-block-replicated, nightly Garage backup → agents/<group>
        egress → vLLM / aperture via Tailscale ExternalName (unchanged)
```

The workspace runs as a **sidecar** in the group's pod and reaches the gateway
over loopback. The browser-facing surface is workspace :3000 only; :8642/:9119
are never exposed publicly (cluster-internal + loopback).

## access & identity

### authn + authz at the edge (the core of multi-tenancy)

`SecurityPolicy.oidc` authenticates but does not restrict *which* users. Group
gating is done in **Pocket ID**, not in k8s:

1. One **Pocket ID OAuth client per group**.
2. That client is restricted to the group's **Pocket ID user-group** (Pocket ID
   refuses to mint a token for a non-member).
3. The group's `SecurityPolicy` references that client's `clientID` + SOPS
   `clientSecret`.

Result: OIDC at the edge becomes authn **and** authz with zero extra k8s policy.
Membership is managed entirely in Pocket ID's UI. A single-person group is a
client whose allowed group has one member.

Mirrors the existing `frigate` / `code-server` SecurityPolicy pattern:
issuer `https://pocket-id.${COMMON_DOMAIN}`, `redirectURL`
`https://<group>.agents.${COMMON_DOMAIN}/oauth2/callback`, `logoutPath: /logout`,
`cookieDomain: agents.${COMMON_DOMAIN}` (scopes the session cookie to the agents
zone so groups don't share cookies with the rest of `${COMMON_DOMAIN}`).

### per-user memory within a group (phase 2)

Envoy Gateway can forward an OIDC claim downstream as a header (claim→header).
Inject the authenticated email/sub and map it to Hermes' `X-Hermes-Session-Key`
so each member of a multi-user group gets a stable, isolated memory scope. Not
required for v1; documented as the upgrade that turns a shared pod from
"trust-only" into real per-user memory separation.

### isolation summary

| layer | between groups | within a group |
|---|---|---|
| edge (subdomain + per-group Pocket ID client/allowed-group) | hard — non-members can't obtain a token | members share the host |
| identity (OIDC email → `X-Hermes-Session-Key`, phase 2) | n/a | per-user memory scope |
| compute/state (Deployment + PVC + `agents/<group>` S3 path) | hard | shared instance |
| internal auth (`API_SERVER_KEY`) | distinct per group | shared group bearer (loopback only) |

Tailscale is **not** in the user entry path. It remains solely the egress
`ExternalName` to the LLM backend.

## one-time shared changes

1. **Gateway listener** — add a `*.agents.${COMMON_DOMAIN}` HTTPS listener to
   `clusters/common/apps/home/local-gateway/gateway-public.yaml`, terminating a
   wildcard cert `wildcard-agents-${COMMON_DOMAIN//./-}` (cert-manager DNS-01,
   same issuer as the existing wildcards). external-dns publishes the wildcard.
2. **Garage** — the `agents` bucket already exists; the component appends one
   `GarageKey` per group to its `keyPermissions` (or each group ships its own
   key — see open question O3).

## kustomize component + per-group overlay

A reusable component holds the full manifest set with placeholder values; each
group is a tiny overlay that supplies its own values via a single source and a
`components:` reference.

```
clusters/common/apps/agents/        # NEW shared component (cluster-agnostic)
  components/hermes-group/
    kustomization.yaml              # kind: Component
    deployment.yaml                 # gateway + workspace sidecar (placeholder name)
    service.yaml
    httproute.yaml                  # <group>.agents.${COMMON_DOMAIN}
    securitypolicy.yaml             # oidc → per-group client
    storagestack.yaml               # PVC + nightly backup → agents/<group>
    garagekey.yaml
    configmap.yaml                  # persona / LLM / Hermes env
    secret.sops.yaml                # API_SERVER_KEY + Pocket ID clientSecret

clusters/talos-ottawa/apps/agents/app/groups/   # per-group overlays
  <group>/
    kustomization.yaml              # components: [hermes-group]; group values
    secret.sops.yaml               # the two encrypted values for this group
```

Per-group **values** (group name, Pocket ID `clientID`, allowed-group, PVC size,
persona prompt, replica policy) are carried in one place per overlay and injected
into the component via Kustomize `replacements` (single ConfigMap → fields across
all resources) plus `nameSuffix`/labels. Target: an overlay is ~1 ConfigMap +
`components:` line + a SOPS secret.

### "add a group" workflow (the payoff)

1. In Pocket ID: create OAuth client `hermes-<group>`, assign its allowed
   user-group, set redirect `https://<group>.agents.${COMMON_DOMAIN}/oauth2/callback`.
2. `mkdir clusters/talos-ottawa/apps/agents/app/groups/<group>` and drop a
   `kustomization.yaml` (component ref + values) and `secret.sops.yaml`
   (`API_SERVER_KEY`, Pocket ID `clientSecret`), `sops --encrypt --in-place`.
3. Append `- groups/<group>` to `app/kustomization.yaml`; add the group's
   `GarageKey` to bucket perms (O3).
4. Commit → Flux reconciles. `https://<group>.agents.${COMMON_DOMAIN}` is live,
   gated to the group's members.

No `cp -r` + sed. The component is the single source of truth for the shape.

## secrets

Per group, SOPS-encrypted in the overlay:
- `API_SERVER_KEY` — the group's gateway bearer (workspace sidecar uses it over
  loopback). Generated per group; not shared with other groups.
- Pocket ID `clientSecret` — for the group's OAuth client.

Decryption via the existing `sops-gpg` ref already wired in `agents/ks.yaml`.

## storage & egress

- Storage: `StorageStack` PVC `ceph-block-replicated`, nightly snapshot to
  `agents/<group>` in the Garage `agents` bucket — identical to existing agents.
- Egress: LLM traffic continues over the Tailscale `ExternalName` ProxyGroup
  (`stpetersburg-vllm` / `aperture`); unchanged.

## out of scope / phase 2

- **scale-to-zero** for idle single-person groups (KEDA HTTP add-on or knative).
  Always-on pod per group for v1; revisit once tenant count and idle ratio are
  known in production.
- **per-user memory header** (OIDC claim→`X-Hermes-Session-Key`).
- **`HermesGroup` CRD/operator** — once the component shape is proven, fold it
  into a controller (on-brand with the existing `StorageStack` /
  `GarageBucket` operators) so a group becomes one short CR. The component is
  deliberately the de-risking step before writing that operator.

## open questions / assumptions

- **O1 — wildcard cert**: assumes cert-manager can issue
  `*.agents.${COMMON_DOMAIN}` via the same DNS-01 issuer as the existing
  wildcards. Verify the issuer covers the two-level wildcard.
- **O2 — replacements ergonomics**: if Kustomize `replacements` for the hostname
  fan-out gets unwieldy, fall back to Flux `postBuild.substituteFrom` a per-group
  ConfigMap (already used by `agents/ks.yaml`) — or accelerate the operator.
- **O3 — Garage keys**: one shared per-group `GarageKey` appended to the bucket
  vs. each group owning its key. Leaning per-group key (revocable per tenant),
  matching the existing pattern.
- **O4 — workspace image pin**: pin `ghcr.io/outsourc-e/hermes-workspace` to a
  digest/tag rather than `:latest` for reproducible Flux reconciliation; confirm
  the tag stream and arch (amd64+arm64 published).
- **O5 — gateway/workspace version compat**: workspace expects gateway API on
  :8642 and dashboard on :9119 with `HERMES_DASHBOARD*` env as the existing
  agents use; confirm the `nousresearch/hermes-agent` pin matches workspace's
  expected API surface.

## verification (for the implementation plan)

- `kustomize build` the ottawa `agents/app` tree renders cleanly with ≥1 group.
- `flux build kustomization agents --path …` shows the new group resources.
- A test group `<g>.agents.${COMMON_DOMAIN}` redirects to Pocket ID, admits a
  member, rejects a non-member, and loads the workspace UI talking to its gateway.
- Existing five Tailscale agents are untouched (diff is purely additive).
