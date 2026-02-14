# swarm-cluster-health Design

## Summary

Temporal worker that consumes kube-events via signal forwarding, runs pattern detectors against incoming events, and maintains queryable alert state. No automated remediation — detection and queryable alerts only.

## Architecture

- One `ClusterHealthWorkflow` per cluster (robbinsdale, ottawa, stpetersburg)
- Receives `EventBatch` signals forwarded from kube-events watcher
- Runs 4 detectors as pure functions against each event
- Maintains rolling alert state, exposed via Temporal queries
- ContinueAsNew every 5 minutes carrying forward DetectorState
- Separate binary (`swarm-cluster-health`), separate task queue, shares `internal/platform`

## Event Flow

```
K8s API → watcher.go → SignalWorkflow(cluster-watch-{name})     [existing]
                      → SignalWorkflow(cluster-health-{name})    [new]
                                          ↓
                              ClusterHealthWorkflow
                                          ↓
                              run detectors on each event
                                          ↓
                              update ActiveAlerts / AlertHistory
                                          ↓
                              queryable via "active-alerts" / "alert-history"
```

## Detectors (v1)

### CrashLoopBackOff
- Match: `Reason == "BackOff"`, `Type == "Warning"`
- Threshold: 3 events in 10 minutes per pod
- Clear: no new events for 10 minutes

### OOMKilled
- Match: `Reason == "OOMKilling"`, `Source == "kernel-monitor"`
- Threshold: 1 event (immediate alert)
- Groups by pod to deduplicate

### ImagePullBackOff
- Match: `Reason == "Failed"`, message contains "ImagePullBackOff" or "ErrImagePull"
- Threshold: 3 events in 5 minutes per pod
- Clear: no new events for 10 minutes

### StuckRollout
- Match: `Reason in {"FailedCreate", "FailedScheduling"}`, `Kind in {"ReplicaSet", "Pod"}`
- Threshold: 5 events in 15 minutes per owner
- Clear: no new events for 15 minutes

## Data Model

### Alert
```go
type Alert struct {
    ID         string
    Detector   string    // "crash-loop", "oom-killed", "image-pull", "stuck-rollout"
    Cluster    string
    Namespace  string
    Name       string
    Kind       string
    Message    string
    Count      int
    FirstSeen  time.Time
    LastSeen   time.Time
    Resolved   bool
    ResolvedAt time.Time
}
```

### DetectorState
```go
type DetectorState struct {
    PodWindows   map[string]*EventWindow  // key: "cluster/ns/name"
    OwnerWindows map[string]*EventWindow  // key: "cluster/ns/owner"
    ActiveAlerts map[string]*Alert
    AlertHistory []Alert                  // ring buffer, max 200
}
```

### EventWindow
Rolling time window — stores timestamps, prunes expired entries, reports count.

## Query Handlers

- `active-alerts` → `[]Alert` (unresolved only)
- `alert-history` → `[]Alert` (last 200 resolved)

## File Layout

```
swarm/
├── cmd/swarm-cluster-health/main.go
├── internal/
│   ├── clusterhealth/
│   │   ├── types.go
│   │   ├── workflow.go
│   │   ├── detectors.go
│   │   └── workflow_test.go
│   └── kubevents/types.go          (add HealthWorkflowPrefix const)
├── Dockerfile                       (add cluster-health build target)
└── kustomization/
    └── deployment-health.yaml
```

## kube-events Changes

`watcher.go` adds a second `SignalWorkflow` call after the existing one, forwarding the same `EventBatch` to `cluster-health-{clusterName}`.

## Deployment

- Namespace: `swarm`
- Deployment: `swarm-cluster-health`, Recreate strategy
- Config: YAML via ConfigMap, OAuth via existing SOPS secret
- Tailscale hostname: `swarm-health`
- Task queue: `swarm-cluster-health`
- Flux dependsOn: temporal, swarm (kube-events)

## Future (not v1)

- Cross-cluster coordinator workflow
- Webhook/Slack push alerts
- Automated remediation activities (pod delete, flux reconcile)
- Additional detectors (node pressure, ceph health, cert expiry)
