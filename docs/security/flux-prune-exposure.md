# Flux Kustomization prune exposure (2026-10-17)

Findings-only audit: where `prune: true` can delete objects, how wide each
prune scope is, and where the `kustomize.toolkit.fluxcd.io/prune: disabled`
guard is missing. No manifest change in this PR; the one actionable gap is
recorded as a follow-up.

## Posture

| Signal | Count | Notes |
|---|---|---|
| Kustomizations with `prune: true` | 223 | 99 ottawa / 66 robbinsdale / 58 stpetersburg app pointers + the 3 cluster-level roots (`cluster`, `common-cluster`, `kubernetes-apps`) |
| Kustomizations with `prune: false` | 3 | `default-kubernetes` (ts-secrets) per cluster — deliberate: objects are external-owned/updated in place |
| `include:`/`exclude:` path filters on Flux Kustomizations | 0 | none exist; the only `include:` matches in the tree are configarr app config |

**Scope model:** no Kustomization uses include/exclude patterns, so every
prune scope is exactly the rendered output of one pointer's `path:` — narrow
by construction. The exposure question is therefore not pattern width but
(a) pointer removal and (b) guard coverage on stateful objects.

## Blast radius

architecture.md ("Deleting a pointer deletes the objects", §Kustomize prune):
all three top-level Kustomizations run `prune: true`, so `git rm` of a pointer
**deletes** its objects on the next reconcile. The guard is the annotation

```
kustomize.toolkit.fluxcd.io/prune: disabled
```

present on **135 objects across 126 files** (ottawa 44, robbinsdale 34,
stpetersburg 31, shared base 17, plus doc mentions) — on exactly the
irreplaceable things: Namespaces owned by apps, Ceph CRs, snapshot classes,
PerCon/UPG objects, the bhaiya fence activation set.

## Findings

| # | severity | observation |
|---|---|---|
| P1 | **Medium — follow-up PR** | **Robbinsdale rook-ceph config has zero prune guards.** `base/rook-ceph/rook-ceph-robbinsdale/config/` (11 files: cluster/blockpool/filesystem/storageclass/dashboard×3/toolbox/httproute/volumesnapshot) carries no `prune: disabled`, unlike Ottawa's twins (`cluster`,`blockpool`,`filesystem`,`volumesnapshot` guarded + `preserveFilesystemOnDelete: true`). rb `filesystem.yaml` has `preserveFilesystemOnDelete` but the CRs themselves are unprotected: a mistaken removal of the `rook-ceph-cluster-config` pointer deletes the live `CephCluster`/pools. Follow-up: mirror Ottawa's 4 annotations (+ consider storageclass/toolbox). Additive annotations; no behaviour change; still touching storage — do it in a quiet window. |
| P2 | Info | Root Kustomizations (`clusters/talos-*/flux/config/cluster.yaml`) prune `./clusters/<loc>/flux` and `./clusters/common/flux` and `./kubernetes/apps/<loc>` — the flux-system stack itself is guarded by the bootstrap `prune: disabled` deletions documented in networkpolicy-coverage.md; flux objects are re-creatable from this repo by design. |
| P3 | Info | `bhaiya` pointer (ottawa) has no `targetNamespace` on purpose (activation overlay namespaces everything; a targetNamespace would rewrite the home/bhaiya-gateway-editor RoleBinding). Prune scope = whole rendered tree incl. cross-ns objects — intended, documented inline. |
| P4 | Info | Only 3 `prune: false` in the fleet, all `default-kubernetes`/ts-secrets — correct: those Secrets are written by external tooling and must survive pointer removals. |
| P5 | Info | No `dependsOn`-less orphans observed among prune:true pointers sampled; deletion-order hazard documented in architecture.md (guard-clear then pointer-remove across two revisions). |

**Verdict:** exposure is structural and well-guarded everywhere except P1;
no wide include/exclude patterns exist to audit. Follow-up backlog item:
`rook-ceph-robbinsdale prune: disabled guards`.

## Re-derive

```sh
git grep -l "prune: true" -- kubernetes/ clusters/ | wc -l
git grep -c "prune: disabled" | awk -F: '{s+=$2} END{print s}'
for n in cluster blockpool filesystem; do grep -c "prune: disabled" \
  kubernetes/apps/base/rook-ceph/rook-ceph-{ottawa,robbinsdale}/config/$n.yaml; done
```
