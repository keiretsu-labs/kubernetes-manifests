---
name: Storage Operations
description: >
  Rook-Ceph diagnostics (Ottawa + Robbinsdale) and storage troubleshooting
  for all clusters including local-path on StPetersburg.

  Use when: Ceph health is not OK, PVCs are stuck in Pending, OSD is down,
  pools are near full, or volume attachment errors occur. Also use for
  routine storage capacity monitoring.

  Don't use when: The issue is a pod crash unrelated to storage (use
  pod-troubleshooting). Don't use for Flux reconciliation errors (use
  flux-ops). Don't use for image pull failures (use zot-registry). Don't
  use for general cluster health (use cluster-health — it includes a
  storage summary).

  Outputs: Storage health diagnosis with specific Ceph status, OSD state,
  pool capacity, and PVC status. Remediation steps for identified issues.
requires: []
---

# Storage Operations

## Routing

### Use This Skill When
- Ceph status shows HEALTH_WARN or HEALTH_ERR
- PVCs stuck in Pending or Lost state
- OSD is down or has been marked out
- Pool usage is approaching capacity (>80%)
- Volume attachment errors (FailedAttachVolume, FailedMount, multi-attach)
- Pods stuck because of storage issues
- Routine storage capacity check

### Don't Use This Skill When
- Pod is crashing for non-storage reasons → use **pod-troubleshooting**
- Flux can't reconcile → use **flux-ops**
- Image pull issues → use **zot-registry**
- You want a full health scan including storage → use **cluster-health** (it covers storage at a high level)
- The issue is with the registry, not cluster storage → use **zot-registry**

Storage diagnostics for all 3 clusters. Ottawa and Robbinsdale run Rook-Ceph; StPetersburg uses local-path-provisioner.

## Cluster Contexts

⚠️ **Always use `--context <ctx>`** — never rely on current-context.

| Cluster | Context | Storage |
|---------|---------|---------|
| Ottawa | `talos-ottawa` | Rook-Ceph |
| Robbinsdale | `talos-robbinsdale` | Rook-Ceph |
| StPetersburg | `talos-stpetersburg` | local-path-provisioner |

## Rook-Ceph (Ottawa + Robbinsdale)

### Cluster Health
```bash
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
```
- `HEALTH_OK` — all good
- `HEALTH_WARN` — degraded but functional, investigate
- `HEALTH_ERR` — data at risk, report immediately

### OSD Health
```bash
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd tree
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd df
```
- Verify all OSDs are `up` and `in`
- Check for uneven data distribution (variance >10%)
- Flag OSDs >85% full

### Placement Group Status
```bash
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg stat
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg dump_stuck
```
- All PGs should be `active+clean`
- `degraded`, `undersized`, `stale`, `incomplete` PGs need investigation
- Stuck PGs: check if an OSD is down or a node is unreachable

### Pool Usage
```bash
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph df
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd pool ls detail
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- rados df
```
- Check per-pool usage
- Flag pools >80% capacity
- Note replication factor (should be 3 for data pools)

### Ceph Operator
```bash
kubectl --context <ctx> get pods -n rook-ceph -l app=rook-ceph-operator
kubectl --context <ctx> logs -n rook-ceph -l app=rook-ceph-operator --tail=30
```
- Verify operator is running
- Check for reconciliation errors

## PVC Troubleshooting (All Clusters)

### Unbound PVCs
```bash
kubectl --context <ctx> get pvc -A | grep -v Bound
```
- `Pending` PVC: check events with `kubectl describe pvc <name> -n <ns>`
- Common causes: no available PV, storageClass misconfigured, Ceph pool full

### PVC Capacity
```bash
kubectl --context <ctx> get pvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.status.capacity.storage,CLASS:.spec.storageClassName'
```

### Volume Attachment Issues
```bash
kubectl --context <ctx> get volumeattachments
kubectl --context <ctx> get events -A --field-selector reason=FailedAttachVolume
kubectl --context <ctx> get events -A --field-selector reason=FailedMount
```
- Multi-attach errors: RWO volume still attached to old node after reschedule
- Common fix: delete the stale VolumeAttachment (but verify pod is actually gone first)

## Local-Path (StPetersburg)

```bash
# Check provisioner
kubectl --context talos-stpetersburg get pods -n local-path-storage

# List PVCs
kubectl --context talos-stpetersburg get pvc -A

# Check local-path config
kubectl --context talos-stpetersburg get configmap -n local-path-storage local-path-config -o yaml
```
- local-path provisions on the node where the pod runs
- No replication — if the node dies, data is lost
- Mostly used for AI model caches and ephemeral workloads

## Common Issues

| Symptom | Likely Cause | Action |
|---------|-------------|--------|
| HEALTH_WARN: 1 OSD down | Node offline or OSD crashed | Check node status, OSD pod logs |
| PG degraded | OSD down, rebalancing | Wait if OSD is recovering; escalate if OSD stays down |
| Pool nearfull | Storage capacity | Report — needs OSD expansion or data cleanup |
| PVC Pending | StorageClass mismatch or pool full | Check storageClass exists and pool has capacity |
| FailedMount | Stale VolumeAttachment | Verify old pod is gone, then report |
| local-path Pending | Node selector or path issue | Check provisioner logs |

## Edge Cases

- **HEALTH_WARN after node restart:** Usually transient (PG rebalancing). Wait 5 minutes before escalating.
- **OSD marked out but node is fine:** OSD process crashed — check OSD pod logs, may need restart
- **PVC bound but pod can't mount:** Different node than where the PV lives (RWO constraint) — check node affinity

## Artifact Handoff

For complex storage investigations:
- `mkdir -p /tmp/outputs` before writing any artifacts
- Write findings to `/tmp/outputs/storage-diagnosis.md` including Ceph status, OSD state, and pool usage snapshots.
