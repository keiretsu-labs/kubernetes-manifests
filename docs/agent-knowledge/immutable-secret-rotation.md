# Immutable Secret rotation and server-side dry-run hazard

Date: 2026-10-06 UTC

> Classification: runbook. Finding and required procedure: issue #2908.
> Related Flux hazard: `docs/agent-knowledge/flux-kustomization-immutable-job-wedge.md`
> (immutable Job templates). This document is the Secret case.

Application Secret manifests live in **corp/bhaiya**, not in this repository.
Ottawa Flux only points at that GitRepository (`kubernetes/apps/ottawa/bhaiya/`,
Kustomization `flux-system/bhaiya`, `spec.prune: true`). Rotate those objects
in Bhaiya GitOps; do not recreate them under this pointer.

No Secret values were read or included in this document.

## Failure mode

Kubernetes documents that an immutable Secret's `data` / `stringData` cannot
be updated. Only metadata may change. The API error shape is:

```text
data: Forbidden: field is immutable when immutable is set
```

A read-only Flux **server-side dry-run** of the Ottawa `flux-system/bhaiya`
Kustomization rejected these existing Secrets with that error:

| Secret | Manifest (corp/bhaiya) |
|---|---|
| `bhaiya-ssh-host-key` | `deploy/ssh-host-key.sops.yaml` |
| `bhaiya-ssh-auth` | `deploy/ssh-auth-secret.sops.yaml` |
| `bhaiya-session-capability` | `deploy/session-capability.sops.yaml` |
| `bhaiya-oidc-signing-key` | `deploy/oidc-signing-key.sops.yaml` |
| `bhaiya-mcp-control-auth-v1` | `deploy/mcp-control-auth-secret.sops.yaml` |

All five live objects have `immutable: true`.

That dry-run rejection is **benign for unchanged objects**. Ordinary Flux
reconciliation still applies a revision whose Secret *data* matches the live
object (the finding's reference revision was `90c13ed`, Kustomization
`Ready=True`). The dry-run is not evidence that a data rotation occurred.

It is nevertheless a real landmine. Changing encrypted data under an existing
same-named Secret produces the same API rejection on the apply path. Because
the Kustomization is `prune: true`, a failed apply can withhold unrelated
objects in that path and retry (`retryInterval: 1m`), generating repeated
rejected applies.

## Required rotation procedure

1. Never rotate the encrypted payload in place under an existing immutable
   Secret name.
2. Add a new SOPS Secret with a **new name** (keep `immutable: true`).
3. Change every consumer reference in the **same** coordinated GitOps change,
   including both Bhaiya V1 and Bhaiya-SSH / V2 consumers where applicable.
   Update any fingerprint, `kid`, or workspace-projected public-key env that
   must match the new material.
4. Merge, let Flux reconcile, and verify the new Secret exists and every
   dependent Deployment is healthy before removing the old object.
5. Remove the old Secret from Git only after the new identity is active and
   any application-specific overlap or token invalidation has been accounted
   for. `prune: true` then deletes the live old object.

Name rotation is the default. Do **not** blanket-add
`kustomize.toolkit.fluxcd.io/force: enabled` to these Secrets. Force
replacement deletes and recreates host keys, signing keys, or shared
credentials and can cause identity changes, token invalidation, and
temporary consumer failures. Use force only if a deliberate replacement
procedure explicitly accepts those consequences.

## How to dry-run safely

Server-side dry-run talks to the API server and therefore hits the immutable
`data` gate. Client-side dry-run (`--dry-run=client`) does not, so it cannot
prove the cluster will accept the object.

| Check | How | How to read it |
|---|---|---|
| Live object is immutable | Read-only `tools/kc.sh ot -n bhaiya get secret <name> -o jsonpath='{.immutable}'` | `true` means in-place data edits will be rejected |
| Unchanged same-name Secret | Flux SSA dry-run, or `kubectl apply --dry-run=server --server-side` of the existing object | Rejection with the immutable-field error is expected and **not** a rotation failure |
| Proposed **new** Secret name | `kubectl apply --dry-run=server --server-side` of the new manifest only | Create-path should accept; a Forbidden here is a real problem |
| Proposed Deployment reference swap | Server-side dry-run of the updated Deployment(s) | Confirms the new `secretKeyRef` / volume name is schema-valid; it does not prove the Secret exists until apply |

Rules:

- Treat an SSA dry-run of an **unchanged** immutable Secret as a known false
  positive. Do not wedge a Kustomization, add `force`, or rewrite Secret data
  to “fix” it.
- To validate a rotation, dry-run the **new name** (create) and the consumer
  reference updates. Do not dry-run an in-place data patch of the old name
  expecting success.
- Do not `kubectl apply` / `patch` / `replace` these objects for real. GitOps
  only. `kubectl apply` also cannot resolve Flux `${VARIABLE}` substitutions.

## Per-Secret consumers and extra constraints

Re-check live references with `tools/refs.sh` in this repo and a name search
in corp/bhaiya before rotating. The table is the 2026-10-06 inventory.

### `bhaiya-ssh-host-key`

Stable Ed25519 host identity. Mounted as a file (not env).

| Consumer | Where |
|---|---|
| `bhaiya-ssh` | `deploy/ssh-deployment.yaml` volume `secretName: bhaiya-ssh-host-key` |
| V1 control fingerprint | `deploy/deployment.yaml` `BHAIYA_SSH_HOST_KEY_FINGERPRINT` |
| V2 edge | `v2/deploy/base/deployments.yaml` volume `secretName: bhaiya-ssh-host-key` |

The Secret and SSH Deployment comments already require a new Secret name plus
a Deployment change so replicas never split identity. Update the fingerprint
env on V1 control in the same change. Host-key rotation changes the public
SSH identity: known_hosts / TOFU clients will warn or refuse. Staff the
window; do not combine with an unrelated SSH mux or listener change.

### `bhaiya-ssh-auth`

Private Connect token between the SSH edge and V1 control (`BHAIYA_SSH_AUTH_TOKEN`).

| Consumer | Where |
|---|---|
| V1 control | `deploy/deployment.yaml` |
| `bhaiya-ssh` | `deploy/ssh-deployment.yaml` |

The Secret comment already requires a new name plus a Deployment update:
env-backed Secret changes do not restart pods, and an in-place edit would
split credentials across replicas. Roll both Deployments together. Distinct
from the host key and from the MCP control token.

### `bhaiya-session-capability`

Control-plane Ed25519 capability authority. V1 control mounts private and
public keys. `bhaiya-ssh` requests signatures over its private RPC and never
mounts this Secret. The public key is copied into curated workspace pod env
(`WORKSPACE_SESSION_CAPABILITY_PUBLIC_KEY`).

| Consumer | Where |
|---|---|
| V1 control | `deploy/deployment.yaml` `BHAIYA_SESSION_CAPABILITY_{PRIVATE,PUBLIC}_KEY` |
| V2 control | `v2/deploy/base/deployments.yaml` `BHAIYA_SESSION_SIGNING_KEY` (private) |
| Workspace pods | projected public key in the workspace pod template |

The V1 Deployment comment already describes name rotation together with the
Deployment. Rotate V1 and V2 control in the same change. Workspaces still
holding the old public key will reject new capabilities; plan workspace
roll/recycle after control is healthy, in a staffed window.

### `bhaiya-oidc-signing-key`

Operator-managed RSA key. V1 and V2 both inject `BHAIYA_OIDC_SIGNING_KEY_PEM`
from `signing_key.pem`. Token `kid` is hardcoded `bhaiya-1` in V1
(`internal/oidc/provider.go`) and V2 (`v2/internal/oidc/metadata.go`). There
is no dual-key / dual-`kid` overlap in the current providers: a new key
changes JWKS immediately under the same `kid`.

| Consumer | Where |
|---|---|
| V1 control | `deploy/deployment.yaml` |
| V2 control | `v2/deploy/base/deployments.yaml` |
| Relying parties | Hermes-agent dashboard gate, adopted workspace OIDC (`iss` `https://bhaiya.keiretsu.top` and, during overlap, `https://next.bhaiya.keiretsu.top`) |

The Secret manifest itself has no rotation comment (the gap called out in
#2908). Treat it like the others: new Secret name, swap both V1 and V2
references in one GitOps change, then prune the old name.

Staffed-window / compatibility:

- Existing RS256 tokens signed by the old key fail validation as soon as
  JWKS serves the new modulus under `kid=bhaiya-1`. Sessions must
  authenticate again. This is expected, not a rollback trigger by itself.
- Do **not** rotate this key as part of the V1→V2 OIDC issuer migration
  (`v2/docs/SSH-AND-OIDC.md`). That migration depends on the shared key and
  `kid=bhaiya-1` continuing to validate tokens issued before the switch.
- Rotate V1 and V2 together so both issuer documents publish the same JWKS.
- Adding a second `kid` is a code change, not a Secret-only rotation. Until
  that exists, there is no overlap window.

### `bhaiya-mcp-control-auth-v1`

Private Connect token for `bhaiya.mcp.v1.MCPControlService`. Distinct from
the workspace MCP HMAC (`BHAIYA_MCP_SIGNING_KEY` on Secret `bhaiya-mcp`) and
from the SSH auth token.

| Consumer | Where |
|---|---|
| V1 control | `deploy/deployment.yaml` `BHAIYA_MCP_CONTROL_TOKEN` |
| `bhaiya-mcp` | `deploy/mcp-deployment.yaml` `BHAIYA_MCP_CONTROL_TOKEN` |

`mcp-deployment.yaml` already contains explicit name-based rotation guidance:
update this Secret name in **both** Deployments and roll them together.
Keep that comment. Rotate in a staffed window: a split token breaks control
RPC (workspace projection, route, Garage, provider authorization) until both
sides match. Never reuse the SSH token or workspace signing key.

## After reconcile (read-only)

1. New Secret exists: `tools/kc.sh ot -n bhaiya get secret <new-name>`.
2. Dependent Deployments are Ready (V1 `bhaiya`, `bhaiya-ssh`, `bhaiya-mcp`;
   V2 `bhaiya-v2-control` / `bhaiya-v2-edge` when those references moved).
3. Flux Kustomization `flux-system/bhaiya` (and `bhaiya-v2` if its OCI bundle
   moved) is `Ready=True`.
4. Only then delete the old Secret from Git. Confirm prune removed it.

If the Kustomization is `Ready=False` with the immutable-field error **and**
Git still contains a same-name data change, revert that in-place edit and
follow name rotation instead. Do not force-replace.
