---
name: Cluster Health Scan
description: >
  Full multi-cluster health assessment across all 3 Kubernetes clusters.

  Use when: Running periodic health checks, investigating cross-cluster issues,
  or someone asks "how are the clusters doing?" Covers nodes, pods, Ceph,
  Flux, certs, alerts, and resource utilization.

  Don't use when: Debugging a specific pod failure (use pod-troubleshooting).
  Don't use for Flux-specific reconciliation errors (use flux-ops). Don't
  use for Ceph-specific deep dives (use storage-ops). Don't use for a
  single cluster's issue — this skill scans ALL clusters.

  Outputs: Structured health report covering all 3 clusters with issues
  flagged and severity noted.
requires: []
---

# Cluster Health Scan

## Routing

### Use This Skill When
- Running a scheduled or on-demand health check across all clusters
- Someone asks "what's the cluster status?" or "any issues?"
- Starting a monitoring session and need a baseline
- After a maintenance window to verify everything recovered
- Generating a health report for the heartbeat

### Don't Use This Skill When
- Debugging a specific pod (CrashLoopBackOff, etc.) → use **pod-troubleshooting**
- Flux reconciliation failure on a specific kustomization → use **flux-ops**
- Deep-diving into Ceph health (OSD failures, PG repair) → use **storage-ops**
- Only one cluster needs attention → run targeted commands instead of full scan
- Making changes to fix an issue → use **pr-workflow** for the fix

Comprehensive health check across talos-ottawa, talos-robbinsdale, and talos-stpetersburg.

## Cluster Contexts

⚠️ **Always use `--context <ctx>`** — never rely on current-context, it may not be what you expect.

| Cluster | Context |
|---------|---------|
| Ottawa | `talos-ottawa` |
| Robbinsdale | `talos-robbinsdale` |
| StPetersburg | `talos-stpetersburg` |

## Procedure

Run for each context in `talos-ottawa talos-robbinsdale talos-stpetersburg`:

### 1. Node Health
```bash
kubectl --context <ctx> get nodes -o wide
kubectl --context <ctx> top nodes
```
- Verify all nodes are Ready
- Check for memory/disk/PID pressure
- Flag nodes with high resource utilization (>85%)

### 2. Pod Status
```bash
kubectl --context <ctx> get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl --context <ctx> get pods -A | grep -E 'CrashLoop|ImagePull|Error|Pending|Init:'
```
- List all non-healthy pods by namespace
- For CrashLoopBackOff: pull last 20 lines of logs
- For Pending: check events for scheduling failures

### 3. Resource Utilization
```bash
kubectl --context <ctx> top pods -A --sort-by=memory | head -20
kubectl --context <ctx> top pods -A --sort-by=cpu | head -20
```
- Flag pods using >80% of their memory limit
- Flag namespaces with no resource limits set

### 4. Flux GitOps
```bash
flux --context <ctx> get kustomizations -A
flux --context <ctx> get helmreleases -A
flux --context <ctx> get sources git -A
flux --context <ctx> get sources helm -A
```
- Verify all kustomizations and HelmReleases are Ready
- Check source freshness — stale fetches indicate connectivity issues
- Report any suspended resources

### 5. Helm Releases
```bash
helm --kube-context <ctx> list -A --filter 'failed|pending'
```
- List any releases in failed or pending-upgrade state
- For failed releases: `helm status <release> -n <ns>` for details

### 6. PVC Health
```bash
kubectl --context <ctx> get pvc -A
```
- Flag any unbound or lost PVCs
- Check for PVCs near capacity

### 7. Storage (cluster-specific)

**Ottawa + Robbinsdale (Rook-Ceph):**
```bash
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status
kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph df
```
- Verify HEALTH_OK
- Check OSD status (all up+in)
- Check pool usage (<80%)

**StPetersburg (GPU):**
```bash
kubectl --context talos-stpetersburg get pods -n gpu-operator
kubectl --context talos-stpetersburg exec -n gpu-operator <device-plugin-pod> -- nvidia-smi
```
- Verify GPU operator pods are running
- Check GPU utilization and memory

### 8. Certificates
```bash
kubectl --context <ctx> get certificates -A
kubectl --context <ctx> get certificaterequests -A --field-selector=status.conditions[0].status!=True
```
- Flag certificates expiring within 7 days
- Report any failed certificate requests

### 9. Firing Alerts
```bash
kubectl --context <ctx> exec -n monitoring deploy/kube-prometheus-stack-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/alerts' | jq '.data.alerts[] | select(.state=="firing") | {alert: .labels.alertname, ns: .labels.namespace, severity: .labels.severity}'
```
- Report all firing alerts (skip Watchdog)
- Group by severity

## Output Template

```
=== CLUSTER HEALTH REPORT ===
Timestamp: <ISO timestamp>

[ottawa] Nodes: 3/3 Ready | Pods: 2 unhealthy | Ceph: HEALTH_OK | Flux: OK | Alerts: 0 firing
  - [ottawa] pod kube-system/coredns-abc123: CrashLoopBackOff (OOMKilled)
  - [ottawa] pod media/sonarr-xyz: Pending (Insufficient memory)

[robbinsdale] Nodes: 5/5 Ready | Pods: 0 unhealthy | Ceph: HEALTH_OK | Flux: OK | Alerts: 0 firing

[stpetersburg] Nodes: 1/1 Ready | Pods: 0 unhealthy | GPU: OK | Flux: OK | Alerts: 1 firing
  - [stpetersburg] alert: KubeMemoryOvercommit (warning)

Overall: 2 issues found across 3 clusters
```

## Compaction Notes

Health scans produce large output. For long monitoring sessions:
- `mkdir -p /tmp/outputs` before writing any artifacts
- Write each cluster's results to `/tmp/outputs/health-<cluster>-<date>.md`
- Summarize findings in the report template above
- Only keep actionable items in context — healthy clusters need one line, not full output

## Edge Cases

- **Metrics server down:** `kubectl top` will fail — note this as an issue, don't block the scan
- **Ceph tools pod missing:** Can't run ceph commands — report this as a finding
- **Prometheus not reachable:** Alert check will fail — note and continue with other checks
