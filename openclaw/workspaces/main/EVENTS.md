# Event-Driven Alerting

This document describes how the agent can watch for specific conditions and proactively alert, rather than relying solely on time-based heartbeats.

## Watch Conditions

Monitor for specific event conditions and trigger alerts when those conditions are met.

### Alert Triggers

| Condition | Check Command | Alert Threshold |
|-----------|---------------|-----------------|
| Pod crash | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.containerStatuses[?(@.lastState.terminated.exitCode<0)]}'` | Any crash |
| ImagePullBackOff | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.conditions[?(@.type=="PodScheduled")].message}'` | Contains "ImagePullBackOff" |
| OOMkubectl get pods -Killed | `n openclaw -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}'` | Contains "OOMKilled" |
| Flux reconciliation failure | `flux get kustomization -A \| grep -v Ready` | Any failed reconciliation |
| Pod not Ready | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'` | Any "False" |
| High restart count | `kubectl get pods -n openclaw -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}'` | Any > 5 |
| Recent warning events | `kubectl get events -n openclaw --field-selector type=Warning --since=15m` | Any warnings in 15min |

### Event-Watch Script

Run this to check all alert conditions:

```bash
#!/bin/bash
# event-watch.sh - Check all alert conditions and output JSON

# Check for CrashLoopBackOff or OOMKilled
CRASHES=$(kubectl get pods -n openclaw -o json | jq -r '.items[] | select(.status.containerStatuses[]?.lastState?.terminated?.exitCode < 0) | .metadata.name')
[ -n "$CRASHES" ] && echo "ALERT: critical - Pods with crashes: $CRASHES"

# Check for ImagePullBackOff
PENDING=$(kubectl get pods -n openclaw -o json | jq -r '.items[] | select(.status.phase=="Pending") | .metadata.name')
[ -n "$PENDING" ] && echo "ALERT: critical - Pods pending (ImagePullBackOff?): $PENDING"

# Check Flux reconciliation
FLUX_ERR=$(flux get kustomization -A 2>/dev/null | grep -v "Ready" | grep -v "NAME")
[ -n "$FLUX_ERR" ] && echo "ALERT: high - Flux reconciliation failed: $FLUX_ERR"

# Check for recent warnings
WARNINGS=$(kubectl get events -n openclaw --field-selector type=Warning --since=30m -o json | jq -r '.items[] | "\(.lastTimestamp) \(.reason) \(.message)"')
[ -n "$WARNINGS" ] && echo "ALERT: medium - Recent warnings: $WARNINGS"

# Check for high restart counts
RESTARTS=$(kubectl get pods -n openclaw -o json | jq -r '.items[] | select(.status.containerStatuses[]?.restartCount > 5) | .metadata.name')
[ -n "$RESTARTS" ] && echo "ALERT: high - High restart count: $RESTARTS"
```

### Integration with Heartbeat

Add event-driven checks to the heartbeat cycle:

```bash
# Run event-watch.sh before periodic heartbeat
bash /path/to/event-watch.sh

# If alerts returned, include in heartbeat response:
# ALERT: <severity> - <message>
```

## Proactive Alert Pattern

When the agent detects an alert condition:

1. **Format the alert**: `ALERT: <severity> - <condition> - <details>`
2. **Include context**: What failed, when, and suggested action
3. **Escalate appropriately**:
   - `critical`: Immediate Discord message
   - `high`: Discord message in channel
   - `medium`: Include in next heartbeat response

## Alert Severity Levels

| Severity | Trigger | Action |
|----------|---------|--------|
| **critical** | Pod crash, OOMKilled, ImagePullBackOff | Immediate Discord alert |
| **high** | Flux failure, high restarts (>5) | Discord message |
| **medium** | Warning events, degraded state | Heartbeat inclusion |
| **low** | Informational (e.g., restart succeeded) | Log only |

## Example Alert Outputs

```
ALERT: critical - Pod crash detected - openclaw-xyz123 restarted 3 times in last 10 minutes. Last exit code: 137 (OOMKilled)
ALERT: high - Flux reconciliation failed - openclaw kustomization stuck on revision abc123, error: "git repository not found"
ALERT: medium - Warning events - 2 warning events in last 30min: FailedMount (openclaw ConfigMap)
```

## External AlertManager Integration

### Alert Message Format

Alerts arrive in Discord with format: `[talos-{cluster}] [FIRING:N] {alertname} {message}`

### Response Workflow

1. **Parse** - Extract cluster from `[talos-xxx]`, alertname from message
2. **Context** - Map `talos-{cluster}` to kubectl context (stpetersburg/robbinsdale/ottawa)
3. **Diagnose** - Run cluster-specific kubectl commands based on alertname
4. **Assess** - Determine if real issue vs config/scrape false alarm
5. **Notify** - Ping @Keiretsu-Admins with formatted summary if actionable

### Alert Notification Template

```
<@&1425670630560497766>

**Alert:** `{alertname}` | **Cluster:** {cluster} | **Severity:** {severity}

**Affected:** {instance/pod/node info from labels}

**Assessment:** {real alert / false alarm} - {root cause if known}

**Recommendation:** {action item or "n/a"}
```
