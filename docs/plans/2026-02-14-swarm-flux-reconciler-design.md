# swarm-flux-reconciler Design

## Overview

Temporal worker that watches all Flux CD resources across 3 clusters (Robbinsdale, Ottawa, St. Petersburg) via K8s watches and tracks their reconciliation state in Temporal workflows. Detects failures and signals a dedicated alerts workflow for downstream consumers.

## Decisions

- **Observe + alert** — no auto-remediation (no `flux reconcile` calls)
- **Alerts via Temporal signals** — signal a `flux-alerts` workflow, no external webhooks
- **All Flux resource types** — Kustomizations, HelmReleases, GitRepositories, HelmRepositories, OCIRepositories
- **Same binary, separate deployment** — `cmd/swarm-flux-reconciler` alongside `cmd/swarm-kube-events`
- **K8s watch approach** — real-time via persistent watches, not polling

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  swarm-flux-reconciler process                      │
│                                                     │
│  ┌──────────┐  tsnet  ┌──────────────────────────┐  │
│  │ Temporal  │◄───────►│ Temporal Server (Ottawa)  │  │
│  │ Client    │         └──────────────────────────┘  │
│  └────┬─────┘                                       │
│       │ signal                                      │
│  ┌────▼──────────────────────────────────────┐      │
│  │ Workflows                                 │      │
│  │  flux-watch-robbinsdale (singleton)       │      │
│  │  flux-watch-ottawa      (singleton)       │      │
│  │  flux-watch-stpetersburg (singleton)      │      │
│  │  flux-alerts             (singleton)      │      │
│  └───────────────────────────────────────────┘      │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │ Watch goroutines (15 total)                  │   │
│  │  per cluster: Kustomization, HelmRelease,    │   │
│  │  GitRepository, HelmRepository, OCIRepository│   │
│  └──────┬───────────────────────────────────────┘   │
│         │ tsnet                                     │
│  ┌──────▼───────────────────────────────────────┐   │
│  │ K8s API Servers (via operator proxy)         │   │
│  │  robbinsdale-k8s-operator.keiretsu.ts.net    │   │
│  │  ottawa-k8s-operator.keiretsu.ts.net         │   │
│  │  stpetersburg-k8s-operator.keiretsu.ts.net   │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## Watched Resources

| Group | Version | Resource | Example count (Ottawa) |
|-------|---------|----------|----------------------|
| kustomize.toolkit.fluxcd.io | v1 | kustomizations | 81 |
| helm.toolkit.fluxcd.io | v2 | helmreleases | 38 |
| source.toolkit.fluxcd.io | v1 | gitrepositories | 6 |
| source.toolkit.fluxcd.io | v1 | helmrepositories | 88 |
| source.toolkit.fluxcd.io | v1 | ocirepositories | 5 |

## Data Model

```go
type FluxResourceStatus struct {
    Cluster        string
    Namespace      string
    Name           string
    Kind           string    // Kustomization, HelmRelease, GitRepository, etc.
    Ready          bool      // condition type=Ready, status=True
    Reason         string    // ReconciliationSucceeded, UpgradeFailed, etc.
    Message        string
    Revision       string    // lastAppliedRevision or lastAttemptedRevision
    Suspended      bool      // .spec.suspend
    LastTransition time.Time // when Ready condition last changed
    LastSeen       time.Time // when watcher last observed this resource
}

type FluxAlert struct {
    Cluster   string
    Namespace string
    Name      string
    Kind      string
    Reason    string
    Message   string
    Severity  string    // "error" or "warning"
    FiredAt   time.Time
}
```

## Workflow: flux-watch-{cluster}

Per-cluster singleton. ContinueAsNew every 10min or 2000 status updates.

**Signals:**
- `status-update` — receives `FluxStatusBatch` from watchers
- `alerts-ack` — acknowledge/dismiss an alert

**Queries:**
- `resources` — returns map of all tracked resource statuses
- `alerts` — returns active (unresolved) alerts for this cluster
- `summary` — returns counts by state (ready, failed, suspended, unknown)

**Alert triggers:**
- Ready=True → Ready=False transition (new failure)
- Resource stays Ready=False for >5min (sustained failure, re-alert)
- Source resource goes not-ready (upstream breakage)

When an alert fires, the workflow signals `flux-alerts` workflow.

## Workflow: flux-alerts

Global singleton. ContinueAsNew every 30min.

**Signals:**
- `alert` — receives `FluxAlert` from watch workflows

**Queries:**
- `active` — returns unresolved alerts
- `history` — returns last 100 resolved alerts

## Watcher Pattern

Each watch goroutine:
1. Creates dynamic client for cluster via `NewDynamicKubeClient`
2. Lists all resources of one GVR (initial sync)
3. Opens watch from list resourceVersion
4. On ADDED/MODIFIED: extracts status from unstructured, batches
5. On DELETED: signals tombstone
6. 2-second flush interval (same as kube-events)
7. On watch error: 5s backoff, reconnect

Status extraction from `unstructured.Unstructured`:
- `.status.conditions[]` → find `type=Ready` → extract `status`, `reason`, `message`, `lastTransitionTime`
- `.status.lastAppliedRevision` or `.status.lastAttemptedRevision`
- `.spec.suspend`

## Platform Changes

Add `NewDynamicKubeClient` to `internal/platform/kube.go`:
- Same tsnet transport as existing `NewKubeClient`
- Returns `dynamic.Interface` instead of `*kubernetes.Clientset`
- Existing code untouched

## Config

```yaml
temporal:
  address: "ottawa-temporal.keiretsu.ts.net:7233"
  useTsnet: true
  namespace: "default"
  taskQueue: "swarm-flux-reconciler"
tailscale:
  hostname: "${LOCATION}-swarm-flux"
  tags:
    - "tag:swarm"
clusters:
  - name: robbinsdale
    endpoint: "robbinsdale-k8s-operator.keiretsu.ts.net:443"
  - name: ottawa
    endpoint: "ottawa-k8s-operator.keiretsu.ts.net:443"
  - name: stpetersburg
    endpoint: "stpetersburg-k8s-operator.keiretsu.ts.net:443"
```

## Deployment

- Dockerfile builds both binaries from single image
- Separate Deployment in `swarm` namespace: `swarm-flux-reconciler`
- Own ConfigMap (`swarm-flux-config`), reuses `swarm-secrets`
- Same security context as kube-events (nonroot, drop ALL, seccomp)
- 1 replica, Recreate strategy
- Different tsnet hostname: `${LOCATION}-swarm-flux`

## File Structure

```
swarm/
├── cmd/
│   ├── swarm-kube-events/main.go        # existing, untouched
│   └── swarm-flux-reconciler/main.go    # new entrypoint
├── internal/
│   ├── platform/
│   │   ├── temporal.go                  # existing, untouched
│   │   ├── tsnet.go                     # existing, untouched
│   │   ├── kube.go                      # add NewDynamicKubeClient
│   │   └── fluxwatcher.go              # new: watch + signal loop
│   ├── config/
│   │   └── config.go                    # existing, untouched
│   ├── kubevents/                       # existing, untouched
│   └── fluxmon/
│       ├── types.go                     # constants, structs
│       ├── workflow.go                  # FluxWatchWorkflow
│       ├── alerts_workflow.go           # FluxAlertsWorkflow
│       ├── activities.go                # ListFluxResources activity
│       └── workflow_test.go             # tests
├── kustomization/
│   ├── deployment.yaml                  # existing kube-events
│   ├── deployment-flux-reconciler.yaml  # new
│   ├── config.yaml                      # existing kube-events config
│   ├── config-flux-reconciler.yaml      # new
│   ├── secret.sops.yaml                 # shared
│   └── kustomization.yaml              # updated to include new files
└── Dockerfile                           # updated: builds both binaries
```
