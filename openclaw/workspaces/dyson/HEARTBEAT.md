# Heartbeat Checklist

Run these checks on **all 3 clusters** each heartbeat cycle. Check sequentially: talos-ottawa → talos-robbinsdale → talos-stpetersburg. If everything is healthy across all clusters, reply `HEARTBEAT_OK`.

## Per-Cluster Checks

For each cluster context (`talos-ottawa`, `talos-robbinsdale`, `talos-stpetersburg`):

### 1. API Server
- Can you reach the API server? `kubectl --context <ctx> cluster-info`
- If unreachable, report immediately and skip remaining checks for that cluster

### 2. Nodes
- `kubectl --context <ctx> get nodes -o wide` — all nodes Ready?
- Report any NotReady, SchedulingDisabled, or disk/memory/PID pressure conditions

### 3. Pod Failures
- `kubectl --context <ctx> get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded`
- Report any CrashLoopBackOff, ImagePullBackOff, Pending, or Error pods
- For CrashLoopBackOff: check logs with `kubectl logs --tail=20`

### 4. Flux
- `flux --context <ctx> get kustomizations -A` — all Ready?
- `flux --context <ctx> get helmreleases -A` — all Ready?
- Report any failed reconciliations with the error message

### 5. Recent Events
- `kubectl --context <ctx> get events -A --sort-by='.lastTimestamp' --field-selector type=Warning` (last 30 minutes)
- Report OOMKilled, FailedMount, FailedScheduling, BackOff, Unhealthy events

### 6. Storage
- **Ottawa + Robbinsdale:** `kubectl --context <ctx> exec -n rook-ceph deploy/rook-ceph-tools -- ceph status` — HEALTH_OK?
- Report any degraded PGs, down OSDs, or nearfull warnings
- **StPetersburg:** Check for unbound PVCs: `kubectl --context <ctx> get pvc -A | grep -v Bound`

### 7. Firing Alerts
- Check Prometheus for active alerts (skip informational/watchdog)
- Report any firing alerts with name, namespace, and severity

## Reporting

- Prefix every finding with cluster context: `[ottawa]`, `[robbinsdale]`, `[stpetersburg]`
- If all checks pass across all clusters: reply `HEARTBEAT_OK`
- Don't repeat known issues from previous heartbeats unless status changed
- If a cluster is unreachable, report that and continue checking the other clusters
