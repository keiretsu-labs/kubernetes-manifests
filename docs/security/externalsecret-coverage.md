# ExternalSecret / external-secrets coverage (2026-10-17)

Findings-only audit: which `Secret` manifests in the tree could become
`ExternalSecret`s, and where the ExternalSecrets operator is already the right
tool vs where Flux `${VAR}` substitution is the simpler mechanism. No config
change is proposed; migration candidates are listed for a future lane.

## Current state

- Operator: `external-secrets` HelmRelease v2.12.0
  (`base/external-secrets/external-secrets/install/`), one per cluster via the
  shared base; CRDs CreateReplace; ServiceMonitor on.
- Stores (`config/cluster-secret-stores.yaml`, 157 lines, 7 stores):
  - `kubernetes-ottawa` / `-robbinsdale` / `-stpetersburg` — cross-cluster
    reads via the Tailscale operator API proxy (`<loc>-k8s
    ...keiretsu.ts.net`), bearer `tailscale-api-token` (the `token: "unused"`
    placeholder — auth is tailnet impersonation).
  - `kubernetes-local`, `kubernetes-teslamate`, `kubernetes-local-cert-manager`,
    `kubernetes-bhaiya` — in-cluster reads as SA `external-secrets-store`
    against `kube-root-ca.crt`, scoped by `remoteNamespace`.
- Consumers (7 ExternalSecrets): cliproxy workspace-keys (`kubernetes-bhaiya`),
  firefly-mcp (`kubernetes-local`), cilium-mesh-secrets
  (`kubernetes-local-cert-manager`), ocm-agent bootstrap
  (`kubernetes-ottawa-ocm`, store defined beside the consumer), teslamate
  postgres sync (`kubernetes-teslamate`), woodpecker-robbinsdale secret-sync
  (`kubernetes-ottawa`). Plus two push-style uses: bhaiya pointer lists
  ExternalSecrets in `healthChecks`, and
  `open-cluster-management/.../tailnet-secret-sync-rbac.yaml` documents the
  ocm pull path.

## Inventory: 88 `kind: Secret` manifests (64 base docs + 24 pointer-level)

| Class | Count | Examples | ESO fit |
|---|---|---|---|
| `${VAR}` Flux-substitution shells | 40 | tinyauth, cloudflare tokens, cert-manager issuers, garage admin/rpc, gatus ×3, media ×17, tailscale oauth, teslamate ENCRYPTION_KEY | **Poor.** Values originate in `clusters/*/flux/vars/*-secrets.sops.yaml` and are injected by `postBuild.substituteFrom` at render time. An ExternalSecret would need the same value in a provider anyway — no dedup win, adds a controller to the path. |
| Generated/owned-at-runtime shells (empty `data`, sync Job or controller writes) | ~6 | bhaiya-ops-bot + bot-viewer kubeconfigs, bot-viewer token SA secret, ocm bootstrap-token (SA-token type), remote-tokens `token: unused` | **None.** ESO `creationPolicy: Owner` would fight the owning controller; these are already the pattern ESO docs recommend for generated secrets. |
| Controller-generated via CR `secretTemplate` | ~20 | garage `GarageKey` (16 across garage-keys/-ottawa), firefly/forgejo CNPG, zot, tailscale-examples | **None.** The secret IS the controller output. |
| SOPS-encrypted bundle sources | 6 | `clusters/*/flux/vars/*-secrets.sops.yaml`, ottawa `firefly-source`, bhaiya `forgejo-auth` | **Already the source of truth.** ESO reading these would be circular; decryption lives in the Flux kustomization chain by design. |
| Cross-namespace copies (the real ESO win) | 3 | teslamate-postgres-app → monitoring (done), cilium-mesh token, woodpecker-robbinsdale sync (done) | **Done or candidate.** Remaining: none identified — every cross-ns consumer found already has an ExternalSecret or a documented reason not to. |

## Findings

| # | severity | observation |
|---|---|---|
| E1 | Info | Coverage is intentional and small: 7 ExternalSecrets, all cross-namespace or cross-cluster copies — exactly the gaps ESO exists for. No `Secret` manifest is a forced ESO candidate. |
| E2 | Info | The 40 `${VAR}` substitution Secrets are correct as-is: Flux envsubst is the delivery mechanism for the SOPS var bundles; converting them would duplicate the value stores. |
| E3 | Low | `remote-tokens-secret.yaml` documents `token: "unused"` relied on by all three remote ClusterSecretStores — the "credential" is tailnet identity. If the Tailscale operator ever enforces tokens, all three stores break together; a comment-level risk note exists in the store file. Acceptable; no action. |
| E4 | Info | `kubernetes-ottawa-ocm` store lives in the consumer's own dir (`open-cluster-management-agent/.../bootstrap-secret.yaml`) not the shared config — slightly inconsistent placement, documented in `tailnet-secret-sync-rbac.yaml`. Cosmetic. |
| E5 | Info | `creationPolicy: Owner` used on the sync-type ExternalSecrets; merge/replace patterns absent — no drift risk between Flux and ESO writers observed. |

**Verdict: no-finding requiring action.** ESO is deployed where it pays
(cross-ns/cross-cluster copies) and deliberately not used where Flux
substitution or controller-generated secrets are the simpler owner. No
migration PR warranted; the table above is the record.

## Re-derive

```sh
git grep -l "kind: ExternalSecret" -- kubernetes/ | grep -v sops
git grep -l "kind: Secret" -- kubernetes/apps/base | grep -v sops | xargs grep -l '\${' | wc -l
git grep -n "secretTemplate" -- kubernetes/apps/base | wc -l
```
