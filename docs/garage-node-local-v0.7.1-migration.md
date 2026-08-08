# Garage node-local migration with operator v0.7.1

This runbook moves the ten LocalPath-backed Garage identities in Ottawa,
Robbinsdale, and St. Petersburg to operator-managed node-local pools. The SMB
members and gateway StatefulSets stay unchanged.

The migration uses the online add-before-remove path. New pool members get
fresh HostPath directories and fresh Garage identities; old LocalPath
StatefulSets remain online until the replacements are healthy and the operator
has prepared each old identity for deletion. An old LocalPath `node_key` is
never mounted by a pool pod.

## Baseline captured 2026-08-08

- Garage v2.3.0 and garage-operator v0.6.29 are running in all three clusters.
- Shared layout version 173 is the only live version; older versions are
  Historical, not Draining.
- All 18 Garage processes are connected: 12 storage members and 6 gateways.
- All 256 partitions have quorum and are healthy.
- Every GarageCluster is Ready at its observed generation, with no active
  storage drain or storage rollout.
- Kubernetes is v1.36.3, the validating/conversion webhooks are enabled, and
  the operator is installed cluster-wide.

Final preflight also found six persistent block-resync error hashes replicated
across their expected nodes. Every reported object reference belonged only to
the already-deleted Garage bucket `99aa1da58dc06129`. With explicit approval,
the orphaned references were purged and each node retried its own failed block
work on 2026-08-08. `garage stats --all-nodes` then reported zero block errors
on all 18 processes. The cleanup temporarily populated resync queues, so do not
begin pool enrollment until those queues have also returned to zero.

The source LocalPath identities are:

| Site | GarageNode | Node ID | Capacity |
|---|---|---|---:|
| Ottawa | `ottawa-garage-localpath-asuka` | `73143814f0e608c7737dde755727a45ca9b81414d76da011767fae2b867752fa` | 700Gi |
| Ottawa | `ottawa-garage-localpath-kaji` | `2dc9e50342b9634d0171b4b6b5c4c3fb1a150ee3f57fbe5776f77bba47571fa2` | 700Gi |
| Ottawa | `ottawa-garage-localpath-rei` | `fa7874a6114ec8a311d7ab528f2583b0395b1b0213b280a9f913f020548ac44c` | 700Gi |
| Ottawa | `ottawa-garage-localpath-shiro` | `e5f1f80dd90782d7acee7d2d245a9dae5569cc03a2d5db2246e697edecc8d7d2` | 200Gi |
| Robbinsdale | `robbinsdale-garage-localpath-stone` | `5f627bcb2fd63bd3719240ac3896c2f19b452bc012d2f2ed090f250716830278` | 700Gi |
| Robbinsdale | `robbinsdale-garage-localpath-tank` | `6f021954d0b18b1c2ba276a9bb0a5226df5bf4fe239726cab7c63a038ab5813f` | 700Gi |
| Robbinsdale | `robbinsdale-garage-localpath-titan` | `6beda59d7d710437ca3c7664e4df28e55a3f65d57e9d2fd1dc40cd62f0390924` | 700Gi |
| St. Petersburg | `stpetersburg-garage-localpath-spark-0` | `5b58bb8e679ba9689288b12814e788b5ec8f5217a9bb556d175e33de35762e66` | 2Ti |
| St. Petersburg | `stpetersburg-garage-localpath-spark-1` | `f863543b50d70a7b516c3092520908f90162720a82fd6a5ccfe06069ef0c82b7` | 2Ti |
| St. Petersburg | `stpetersburg-garage-localpath-orin-0` | `2cdded6557c7100c93bb3f5dd5a2dc85cd4abf37e4cb3828813ca37e21acb341` | 200Gi |

## Target pools

| Site | Pool | Selected Nodes | Capacity per member | HostPath prefix |
|---|---|---|---:|---|
| Ottawa | `local-700` | asuka, kaji, rei | 700Gi | `/var/local-path-provisioner/garage-node-local/ottawa-700` |
| Ottawa | `local-200` | shiro | 200Gi | `/var/local-path-provisioner/garage-node-local/ottawa-200` |
| Robbinsdale | `local-700` | stone, tank, titan | 700Gi | `/var/local-path-provisioner/garage-node-local/robbinsdale-700` |
| St. Petersburg | `local-2ti` | spark-0, spark-1 | 2Ti | `/var/local-path-provisioner/garage-node-local/stpetersburg-2ti` |
| St. Petersburg | `local-200` | orin-0 | 200Gi | `/var/local-path-provisioner/garage-node-local/stpetersburg-200` |

Each prefix has separate `metadata` and `data` directories. Both contain a
`.garage-volume-id` marker before a pool is declared, and pools use
`hostPathType: Directory` so a missing mount fails closed.

Pool RPC addresses use a new identity-specific name while old and new members
coexist:

```text
<location>-garage-pool-<kubernetes-node>.keiretsu.ts.net:3901
```

One Tailscale LoadBalancer Service selects each exact pool/node pair by
`garage.rajsingh.info/node-local-pool` and
`garage.rajsingh.info/kubernetes-node`.

## Non-negotiable invariants

1. Durable changes go through this repository and Flux. Do not `kubectl apply`,
   edit, replace, or delete a managed object directly.
2. Never run an old StatefulSet pod and a pool pod against the same metadata
   directory or `node_key`.
3. Only one physical site's operator may mutate the shared Garage topology at
   a time. Wait for one live layout version before changing another site.
4. Retire only one old positive-capacity identity at a time. A second drain
   does not start until the first GarageNode, StatefulSet, and Pod are gone and
   layout history is settled.
5. Before every merge, re-check cluster health, all 256 partitions, connected
   members, `StorageRolloutReady`, `NodeLocalPoolsReady`, and layout history.
6. Never strip a GarageNode finalizer or use `skip-dead-nodes` for a healthy
   source. Stop and investigate any identity mismatch, block error, repair
   backlog, unreachable peer, or unexpected Draining version.
7. Keep source PVCs and PVs through the migration and rollback window. Their
   reclaim policies do not authorize early deletion.

## GitOps sequence

### 1. Release and upgrade the operator

Use v0.7.1 for this migration. Its repair PR and complete E2E matrix passed.
The image and chart signatures and provenance, the image SPDX SBOM attestation,
and the install manifest provenance were independently verified.

The v0.7.0 chart was pushed but its signing/provenance step failed before this
migration began, so it was never deployed. Upgrade the shared HelmRelease to
chart 0.7.1 and wait in all three clusters for:

- HelmRelease Ready with `lastAttemptedRevision: 0.7.1`;
- the operator Deployment at the v0.7.1 image and fully available;
- conversion and validating webhooks serving;
- existing GarageClusters and GarageNodes still Ready at their observed
  generations; and
- the shared layout still at one live version.

### 2. Prepare storage and network endpoints

In one non-topology PR:

- label each `garage` namespace for HostPath admission;
- create per-node marker Jobs that mount only the new empty HostPaths;
- create the new identity-specific Tailscale Services;
- add no-op Flux substitution points for per-site pools, consistency mode, and
  drain peer policy.

Wait for every marker Job to complete and confirm each Service has the exact
future pool/node selector. Before a pool pod exists,
`TailscaleIngressSvcConfigured=False` with reason
`IngressSvcNoBackendsConfigured` is the expected fail-closed state; no
LoadBalancer address should be published yet. Completed Jobs mount nothing and
may remain until the pool is healthy.

### 3. Add replacement pool members one site at a time

Declare pools through the site's `GARAGE_NODE_LOCAL_POOLS` value in this order:

1. Ottawa; wait for every pool member and the shared layout to converge.
2. Robbinsdale; repeat the same gates.
3. St. Petersburg; repeat the same gates.

For each site, require:

- every expected DaemonSet pod Ready on its exact Node;
- every pool Service reports `TailscaleIngressSvcConfigured=True`, publishes
  its expected identity-specific `.keiretsu.ts.net` hostname, and reaches the
  matching pod on RPC port 3901;
- every generated GarageNode has a new 64-hex identity, is Connected and
  InLayout, and has the intended zone/capacity/RPC address;
- `NodeLocalPoolsReady=True` and `StorageRolloutReady=True` at the current
  GarageCluster generation;
- 12 old storage members plus all new members healthy while they overlap;
- all partitions healthy, no block errors, repair/resync queues settled; and
- layout history back to one live version before the next site is changed.

### 4. Enter drain-safe consistency mode

Change `GARAGE_CONSISTENCY_MODE` to `consistent` one site at a time, waiting for
that site's serialized workload rollout and global health before changing the
next site. After every process at all three sites is running literal consistent
mode, set `GARAGE_DRAIN_PEER_POLICY` to `AssumeConsistent` at each site, again
one site at a time.

Do not combine these runtime/config changes with a membership removal.

### 5. Retire each old identity

For each old GarageNode, use two separate merged PRs:

1. Add `garage.rajsingh.info/drain: "true"` to that exact manifest. Wait for
   `DrainPrepared=True` with reason `PreparedForDeletion`, a settled repair
   state, healthy partitions, and one live layout version.
2. Remove that exact GarageNode manifest and its old RPC Service. Wait for the
   GarageNode finalizer, StatefulSet, and Pod to disappear, then re-run every
   health and layout gate before starting another node.

Re-evaluate actual data placement before each drain. The initial low-risk order
is Ottawa (kaji, rei, shiro, asuka), Robbinsdale (tank, titan, stone), then
St. Petersburg (spark-0, spark-1, orin-0), but live health overrides this
suggestion.

### 6. Stabilize and clean up

After all ten old identities are absent and the pool identities have remained
healthy through a full observation window:

- remove the completed marker Jobs;
- remove any remaining old RPC Services;
- restore `degraded` consistency one site at a time only after no drain or
  layout change remains;
- restore the default peer policy in a later configuration-only change; and
- retain old PVCs/PVs until a separate reviewed cleanup confirms the exact old
  role is absent, the source Pod is gone, and the rollback window is closed.

The migration is complete only when Git and all three live clusters agree on
the pool membership, all Flux and Helm resources are Ready, Garage has one live
layout version, all partitions are healthy, every expected pool identity is
Connected/InLayout, and no old LocalPath StatefulSet or GarageNode remains.
