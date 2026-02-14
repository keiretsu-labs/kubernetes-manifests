# Swarm Consolidated Architecture Design

## Summary

Consolidate three separate planned workers (cluster-health, flux-reconciler, tailscale-lifecycle) into a single `swarm` binary with one Temporal worker, one tsnet device, one deployment. Fix ContinueAsNew state loss, eliminate signal fan-out, unify alert models, and address all implementation bugs from the original plans.

## Decisions

- **Single binary** — `cmd/swarm/main.go` replaces `cmd/swarm-kube-events/main.go`
- **Single task queue** — `swarm` replaces `swarm-kube-events`
- **Detectors inline** — cluster-health detectors run inside `ClusterWatchWorkflow` signal handler, no fan-out
- **Unified alerts** — one `alerts.Alert` type, one `AlertsWorkflow` singleton
- **State preserved** — all workflows carry state through ContinueAsNew inputs
- **No separate FluxAlertsWorkflow** — flux failures signal the unified alerts workflow

## Architecture

```
cmd/swarm/main.go
internal/
├── alerts/              unified alert model + global alerts workflow
│   ├── types.go
│   ├── workflow.go
│   └── workflow_test.go
├── clusterhealth/       pure-function detectors (no workflow of their own)
│   ├── types.go
│   ├── detectors.go
│   └── detectors_test.go
├── fluxmon/             flux watch workflow + shared extract
│   ├── types.go
│   ├── extract.go       single extractStatus function
│   ├── workflow.go
│   ├── activities.go
│   └── workflow_test.go
├── tslifecycle/         device cleanup + connectivity probes
│   ├── types.go
│   ├── activities.go
│   ├── cleanup_workflow.go
│   ├── probe_workflow.go
│   └── *_test.go
├── config/              add lifecycle section
├── kubevents/           modified: carry DetectorState, run detectors inline
└── platform/            add NewDynamicKubeClient, fluxwatcher.go
```

## Workflows (8 total on one worker)

| Workflow ID | Package | ContinueAsNew | State Carried |
|-------------|---------|---------------|---------------|
| `cluster-watch-{cluster}` | kubevents | 5min or 1000 events | ResourceVersion, DetectorState |
| `flux-watch-{cluster}` | fluxmon | 10min or 2000 updates | Resources map |
| `swarm-alerts` | alerts | 30min | Active alerts, History (200 max) |
| `tailscale-device-cleanup` | tslifecycle | 24h | Last CleanupResult |
| `tailscale-connectivity-probe` | tslifecycle | 5min | Probe history (100 max) |

## Unified Alert Model

```go
type Alert struct {
    ID         string
    Source     string    // "cluster-health" or "flux-reconciler"
    Detector   string    // "crash-loop", "oom-killed", "image-pull", "stuck-rollout", "flux-not-ready"
    Severity   string    // "error" or "warning"
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

AlertsWorkflow receives alerts via signal from any source. Carries Active + History through ContinueAsNew.

## Inline Detectors (no fan-out)

watcher.go is UNCHANGED. ClusterWatchWorkflow runs detectors in its signal handler:

```go
sel.AddReceive(eventsCh, func(ch workflow.ReceiveChannel, more bool) {
    var batch EventBatch
    ch.Receive(ctx, &batch)
    events = append(events, batch.Events...)
    now := workflow.Now(ctx)
    for _, ev := range batch.Events {
        clusterhealth.DetectCrashLoop(ev, detectorState, now)
        clusterhealth.DetectOOMKilled(ev, detectorState, now)
        clusterhealth.DetectImagePull(ev, detectorState, now)
        clusterhealth.DetectStuckRollout(ev, detectorState, now)
    }
    clusterhealth.ResolveStaleAlerts(detectorState, now)
})
```

New alerts are collected via query handler, not cross-workflow signals (simpler).

## Flux State Preservation

FluxWatchInput carries resources through ContinueAsNew:

```go
type FluxWatchInput struct {
    Name      string
    Endpoint  string
    Resources map[string]FluxResourceStatus  // carried forward
}
```

## OOM Detection Fix

Match both kubelet and kernel-monitor events:

```go
func DetectOOMKilled(ev KubeEvent, ...) {
    if !strings.Contains(ev.Reason, "OOM") { return }
    // ...
}
```

## Parallel Connectivity Probes

Bounded concurrency (10 goroutines max) instead of sequential:

```go
sem := make(chan struct{}, 10)
var wg sync.WaitGroup
for _, t := range targets {
    wg.Add(1)
    go func(target ProbeTarget) {
        defer wg.Done()
        sem <- struct{}{}
        defer func() { <-sem }()
        // dial + measure
    }(t)
}
```

## Device Cleanup Dry-Run

CleanupInput gains DryRun field. When true, logs deletions without calling DeleteDevice.

## Config

```yaml
temporal:
  address: "ottawa-temporal.keiretsu.ts.net:7233"
  useTsnet: true
  namespace: "default"
  taskQueue: "swarm"
tailscale:
  hostname: "${LOCATION}-swarm"
  tags: ["tag:swarm"]
clusters:
  - name: robbinsdale
    endpoint: "robbinsdale-k8s-operator.keiretsu.ts.net:443"
  - name: ottawa
    endpoint: "ottawa-k8s-operator.keiretsu.ts.net:443"
  - name: stpetersburg
    endpoint: "stpetersburg-k8s-operator.keiretsu.ts.net:443"
lifecycle:
  cleanupTags: ["tag:k8s", "tag:ottawa"]
  inactiveDays: 30
  dryRun: false
  probeTargets:
    - name: robbinsdale-k8s-api
      address: "robbinsdale-k8s-operator.keiretsu.ts.net:443"
    - name: ottawa-k8s-api
      address: "ottawa-k8s-operator.keiretsu.ts.net:443"
    - name: stpetersburg-k8s-api
      address: "stpetersburg-k8s-operator.keiretsu.ts.net:443"
  probeDynamicTags: ["tag:k8s"]
```

## Deployment

Single deployment named `swarm`. Image: `oci.killinit.cc/swarm/swarm:latest`. One Dockerfile building one binary.

## Implementation Order

1. Rename binary: `swarm-kube-events` -> `swarm`
2. Add lifecycle config types
3. Unified alert types + AlertsWorkflow
4. Cluster health detectors (pure functions)
5. Wire detectors into ClusterWatchWorkflow
6. Flux types + shared extractStatus
7. FluxWatchWorkflow (with state preservation)
8. Dynamic K8s client + flux watcher loop
9. Tailscale lifecycle types + activities
10. DeviceCleanupWorkflow (with dry-run)
11. ConnectivityProbeWorkflow (parallel probes)
12. Wire everything into cmd/swarm/main.go
13. Update Dockerfile + K8s manifests
14. Final verification
