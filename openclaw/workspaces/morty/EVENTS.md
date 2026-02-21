# Operational Memory

This document describes how Morty can watch for specific conditions and proactively alert, rather than relying solely on time-based heartbeats.

## Watch Conditions

Instead of periodic heartbeats, Morty can monitor for specific event conditions and trigger alerts when those conditions are met.

### Alert Triggers

| Condition | Check Command | Alert Threshold |
|-----------|---------------|-----------------|
| Pod crash | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.containerStatuses[?(@.lastState.terminated.exitCode<0)]}'` | Any crash |
| ImagePullBackOff | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.conditions[?(@.type=="PodScheduled")].message}'` | Contains "ImagePullBackOff" |
| OOMKilled | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}'` | Contains "OOMKilled" |
| Flux reconciliation failure | `flux get kustomization -A \| grep -v Ready` | Any failed reconciliation |
| Pod not Ready | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'` | Any "False" |
| High restart count | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}'` | Any > 5 |
| Recent warning events | `kubectl get events -n openclaw --field-selector type=Warning --since=15m` | Any warnings in 15min |

### Event-Watch Script

Run this to check all alert conditions:

```bash
#!/bin/bash
# event-watch.sh - Check all alert conditions and output JSON

ALERTS=[]

# Check for CrashLoopBackOff or OOMKilled
CRASHES=$(kubectl get pods -n openclaw -o json | jq -r '.items[] | select(.status.containerStatuses[]?.lastState?.terminated?.exitCode < 0) | .metadata.name')
if [ -n "$CRASHES" ]; then
  ALERTS=$(echo "$ALERTS" | jq --arg msg "$CRASHES" '. + [{severity: "critical", message: "Pods with crashes: \($msg)"}]')
fi

# Check for ImagePullBackOff
IMAGE_ERR=$(kubectl get pods -n openclaw -o json | jq -r '.items[] | select(.status.phase=="Pending") | .metadata.name')
if [ -n "$IMAGE_ERR" ]; then
  ALERTS=$(echo "$ALERTS" | jq --arg msg "$IMAGE_ERR" '. + [{severity: "critical", message: "Pods with ImagePullBackOff: \($msg)"}]')
fi

# Check Flux reconciliation
FLUX_ERR=$(flux get kustomization -A 2>/dev/null | grep -v "Ready" | grep -v "NAME")
if [ -n "$FLUX_ERR" ]; then
  ALERTS=$(echo "$ALERTS" | jq --arg msg "$FLUX_ERR" '. + [{severity: "high", message: "Flux reconciliation failed: \($msg)"}]')
fi

# Check for recent warnings
WARNINGS=$(kubectl get events -n openclaw --field-selector type=Warning --since=30m -o json | jq -r '.items[] | "\(.lastTimestamp) \(.reason) \(.message)"')
if [ -n "$WARNINGS" ]; then
  ALERTS=$(echo "$ALERTS" | jq --arg msg "$WARNINGS" '. + [{severity: "medium", message: "Recent warnings: \($msg)"}]')
fi

# Output
echo "$ALERTS" | jq .
```

### Integration with Heartbeat

Add event-driven checks to HEARTBEAT.md by including the watch script:

```bash
# Run event-watch.sh before periodic heartbeat
bash /path/to/event-watch.sh

# If alerts returned, include in heartbeat response:
# ALERT: <severity> - <message>
```

## Proactive Alert Pattern

When Morty detects an alert condition, it should:

1. **Format the alert**: `ALERT: <severity> - <condition> - <details>`
2. **Include context**: What failed, when, and suggested action
3. **Escalate appropriately**:
   - `critical`: Immediate Discord message with @mention
   - `high`: Discord message, no @mention
   - `medium`: Include in next heartbeat response

## Example Alert Output

```
ALERT: critical - Pod crash detected - openclaw-xyz123 restarted 3 times in last 10 minutes. Last exit code: 137 (OOMKilled)
ALERT: high - Flux reconciliation failed - openclaw kustomization stuck on revision abc123, error: "git repository not found"
ALERT: medium - Warning events - 2 warning events in last 30min: FailedMount (openclaw ConfigMap)
```

---

# Alert Response

This section documents how to respond to alerts from AlertManager, including expected labels and diagnostic steps for each alert type.

## Expected AlertManager Labels

When AlertManager sends alerts, they include these labels:

| Label | Description | Example |
|-------|-------------|---------|
| `cluster` | Cluster identifier (use for context selection) | `ottawa`, `robbinsdale`, `stpetersburg` |
| `namespace` | Kubernetes namespace | `openclaw`, `flux-system` |
| `alertname` | Alert type | `PodCrashLoopBackOff`, `FluxReconcileFailure` |
| `severity` | Alert severity level | `critical`, `warning`, `info` |
| `pod` | Affected pod name (when applicable) | `openclaw-6b86c8b9c7-abcde` |
| `reason` | Short reason code | `BackOff`, `ImagePull` |

## Alert-to-Action Mapping

### PodCrashLoopBackOff

**Triggers when:** A pod is restarting repeatedly (exit code < 0 multiple times)

**Diagnostic steps:**
```bash
# 1. Get pod status and restarts
kubectl --context=<cluster> get pods -n openclaw -o wide

# 2. Check container logs (last crash)
kubectl --context=<cluster> logs <pod> -n openclaw -c openclaw --previous --tail=100

# 3. Describe pod for events
kubectl --context=<cluster> describe pod <pod> -n openclaw

# 4. Check exit code
kubectl --context=<cluster> get pods <pod> -n openclaw -o jsonpath='{.status.containerStatuses[*].lastState.terminated.exitCode}'
```

**Common causes:** Application crash, OOM, missing config, init container failure

---

### FluxReconcileFailure

**Triggers when:** Flux cannot reconcile a Kustomization or HelmRelease

**Diagnostic steps:**
```bash
# 1. Get Flux status
flux --context=<cluster> get kustomization -A

# 2. Get reconciliation errors
flux --context=<cluster> get kustomization openclaw -n openclaw

# 3. Check Flux logs
kubectl --context=<cluster> logs -n flux-system deploy/flux-source-controller --tail=50
kubectl --context=<cluster> logs -n flux-system deploy/flux-kustomize-controller --tail=50

# 4. Check source availability
flux --context=<cluster> get source all -A
```

**Common causes:** Git repository unreachable, manifest syntax error, missing CRD, image pull error

---

### ImagePullBackOff

**Triggers when:** Kubernetes cannot pull a container image

**Diagnostic steps:**
```bash
# 1. Check pod status
kubectl --context=<cluster> get pods -n openclaw

# 2. Describe pod for pull error details
kubectl --context=<cluster> describe pod <pod> -n openclaw | grep -A10 "ImagePull"

# 3. Verify image exists and is accessible
# Check imagePullSecret is configured
kubectl --context=<cluster> get pod <pod> -n openclaw -o jsonpath='{.spec.imagePullSecrets}'

# 4. Test image manually (if skopeo available)
skopeo inspect docker://<image-url>
```

**Common causes:** Typo in image name, image not in registry, missing imagePullSecret, rate limiting

---

### PodEvicted

**Triggers when:** A pod was evicted from a node

**Diagnostic steps:**
```bash
# 1. Check pod events
kubectl --context=<cluster> get events -n openclaw --field-selector involvedObject.name=<pod> --sort-by='.lastTimestamp'

# 2. Describe pod for eviction reason
kubectl --context=<cluster> describe pod <pod> -n openclaw

# 3. Check node resources
kubectl --context=<cluster> top nodes
kubectl --context=<cluster> top pods -n openclaw

# 4. Check node conditions
kubectl --context=<cluster> get nodes -o json | jq '.items[] | select(.metadata.name=="<node>") | .status.conditions'
```

**Common causes:** Node resource pressure (CPU/memory/disk), node disk pressure, node memory pressure

---

### OOMKilled

**Triggers when:** Container exceeded memory limit and was killed

**Diagnostic steps:**
```bash
# 1. Check container status for OOMKilled
kubectl --context=<cluster> get pods <pod> -n openclaw -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'

# 2. Check memory limits
kubectl --context=<cluster> get pod <pod> -n openclaw -o jsonpath='{.spec.containers[*].resources.limits}'

# 3. Check application memory usage (if accessible)
kubectl --context=<cluster> exec <pod> -n openclaw -c openclaw -- cat /proc/meminfo

# 4. Review logs before OOM
kubectl --context=<cluster> logs <pod> -n openclaw -c openclaw --previous --tail=50
```

**Common causes:** Memory limit too low, memory leak, sudden memory spike

---

### PVCOBound

**Triggers when:** PVC is stuck in Bound state (volume not attaching)

**Diagnostic steps:**
```bash
# 1. Check PVC status
kubectl --context=<cluster> get pvc -n openclaw

# 2. Describe PVC for events
kubectl --context=<cluster> describe pvc <pvc> -n openclaw

# 3. Check PV status
kubectl --context=<cluster> get pv
kubectl --context=<cluster> describe pv <pv-name>

# 4. Check storage class
kubectl --context=<cluster> get storageclass
```

**Common causes:** Storage controller issue, node network problem, volume leak

---

## Cross-Cluster Alert Response Pattern

When receiving an alert, use the `cluster` label to select the correct kubectl context:

```bash
# Parse cluster from alert and set context
ALERT_CLUSTER="ottawa"  # from alert labels
kubectl config use-context $ALERT_CLUSTER

# Then run diagnostic commands
kubectl --context=$ALERT_CLUSTER get pods -n openclaw
flux --context=$ALERT_CLUSTER get kustomization -A
```

### Full Cross-Cluster Alert Script

```bash
#!/bin/bash
# alert-response.sh - Respond to alerts across clusters

CLUSTER="${1:-ottawa}"  # Pass cluster from alert label
ALERT_NAME="${2:-unknown}"
NAMESPACE="${3:-openclaw}"

echo "=== Alert Response ==="
echo "Cluster: $CLUSTER"
echo "Alert: $ALERT_NAME"
echo "Namespace: $NAMESPACE"
echo ""

# Validate cluster context exists
if ! kubectl config get-contexts "$CLUSTER" >/dev/null 2>&1; then
  echo "ERROR: Unknown cluster context: $CLUSTER"
  echo "Available contexts: $(kubectl config get-contexts -o name | tr '\n' ' ')"
  exit 1
fi

echo "Using context: $CLUSTER"
kubectl config use-context "$CLUSTER"

# Run alert-specific diagnostics
case "$ALERT_NAME" in
  PodCrashLoopBackOff)
    echo "=== Pod Status ==="
    kubectl --context=$CLUSTER get pods -n $NAMESPACE -o wide
    echo "=== Recent Events ==="
    kubectl --context=$CLUSTER get events -n $NAMESPACE --field-selector type=Warning --sort-by='.lastTimestamp' | tail -10
    ;;
  FluxReconcileFailure)
    echo "=== Flux Status ==="
    flux --context=$CLUSTER get kustomization -A
    echo "=== Flux Errors ==="
    flux --context=$CLUSTER get kustomization openclaw -n $NAMESPACE
    ;;
  ImagePullBackOff)
    echo "=== Pending Pods ==="
    kubectl --context=$CLUSTER get pods -n $NAMESPACE --field-selector status.phase=Pending
    ;;
  *)
    echo "=== General Status ==="
    kubectl --context=$CLUSTER get pods -n $NAMESPACE -o wide
    kubectl --context=$CLUSTER get events -n $NAMESPACE --sort-by='.lastTimestamp' --field-selector type=Warning | tail -5
    ;;
esac
```

## Alert Severity Response

| Severity | Response Time | Action |
|----------|---------------|--------|
| `critical` | Immediate | DM Discord with @mention, start incident |
| `high` | < 5 min | Discord message, begin triage |
| `warning` | < 30 min | Log to heartbeat, investigate |
| `info` | Next heartbeat | Log for awareness |
