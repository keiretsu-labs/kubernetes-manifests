# Karmada Multi-Cluster Setup (Pull Mode)

Karmada provides multi-cluster workload scheduling with automatic failover.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Karmada Control Plane                        │
│                      (Ottawa Cluster)                           │
│  ┌─────────────┐ ┌──────────────┐ ┌─────────────┐              │
│  │  Karmada    │ │   Karmada    │ │  Karmada    │              │
│  │ API Server  │ │  Controller  │ │  Scheduler  │              │
│  └──────┬──────┘ └──────────────┘ └─────────────┘              │
│         │                                                       │
│         │ Exposed via Tailscale (karmada-apiserver.keiretsu)   │
└─────────┼───────────────────────────────────────────────────────┘
          │
    ┌─────┴─────┬─────────────────┐
    │           │                 │
    ▼           ▼                 ▼
┌───────┐  ┌──────────┐  ┌─────────────┐
│Ottawa │  │Robbinsdale│  │St Petersburg│
│ Agent │  │  Agent   │  │    Agent    │
└───────┘  └──────────┘  └─────────────┘
```

- **Control Plane**: Ottawa cluster
- **Member Clusters**: Ottawa, Robbinsdale, St Petersburg (via agents)
- **Failover Priority**: Ottawa → Robbinsdale → St Petersburg

## Pull Mode vs Push Mode

This setup uses **Pull Mode** with karmada-agents:

| Aspect | Push Mode | Pull Mode (This Setup) |
|--------|-----------|------------------------|
| Connection | Control plane → Member clusters | Member clusters → Control plane |
| Credentials | Control plane needs kubeconfigs for all members | Agents need credentials to control plane |
| GitOps | Requires bootstrap scripts | Fully declarative |
| Network | Control plane must reach all members | Only members must reach control plane |

## Components

### Control Plane (Ottawa)

- `karmada-apiserver` - API server for Karmada resources
- `karmada-controller-manager` - Manages propagation and failover
- `karmada-scheduler` - Schedules workloads to clusters
- `karmada-webhook` - Admission webhooks
- `karmada-aggregated-apiserver` - Aggregated API server
- `etcd` - Stores Karmada state

### Member Clusters (All)

- `karmada-agent` - Connects to control plane, registers cluster, pulls workloads

## Directory Structure

```
clusters/talos-ottawa/apps/
├── karmada-system/        # Control plane (host mode)
│   ├── app/
│   │   ├── helmrelease.yaml      # Karmada control plane
│   │   ├── tailscale-service.yaml # Expose API via Tailscale
│   │   └── kustomization.yaml
│   └── clusters/
│       └── README.md             # This file
│
└── karmada-agent/         # Agent for Ottawa as member
    └── app/
        ├── helmrelease.yaml      # Agent deployment
        └── secret.sops.yaml      # Encrypted credentials

clusters/talos-robbinsdale/apps/
└── karmada-agent/         # Agent for Robbinsdale
    └── app/
        ├── helmrelease.yaml
        └── secret.sops.yaml

clusters/talos-stpetersburg/apps/
└── karmada-agent/         # Agent for St Petersburg
    └── app/
        ├── helmrelease.yaml
        └── secret.sops.yaml
```

## Initial Setup

### Step 1: Deploy Control Plane

The control plane deploys automatically via Flux on Ottawa.
Wait for it to become ready:

```bash
kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
  -n karmada-system get pods
```

### Step 2: Verify Tailscale Exposure

Check that the Karmada API is exposed via Tailscale:

```bash
kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
  -n karmada-system get svc karmada-apiserver-ts

# Should show a Tailscale IP assigned
```

Verify it's reachable:
```bash
curl -k https://karmada-apiserver.keiretsu.ts.net:5443/healthz
```

### Step 3: Generate Agent Credentials

Agents need certificates to authenticate to Karmada. Generate them:

```bash
# Get Karmada kubeconfig (contains CA cert)
kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
  -n karmada-system get secret karmada-kubeconfig \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/karmada.kubeconfig

# Extract CA certificate
kubectl --kubeconfig=/tmp/karmada.kubeconfig config view --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d

# For each cluster, create a certificate signing request
# Option 1: Use karmadactl (recommended)
karmadactl register --cluster-name=robbinsdale \
  --karmada-kubeconfig=/tmp/karmada.kubeconfig \
  --print-manifest-only > /tmp/agent-robbinsdale.yaml

# Option 2: Manually create CSR and approve
```

### Step 4: Update SOPS Secrets

For each cluster, update the secret.sops.yaml with real credentials:

```bash
cd clusters/talos-robbinsdale/apps/karmada-agent/app/

# Edit with real values
vim secret.sops.yaml

# Encrypt with SOPS
sops --encrypt --in-place secret.sops.yaml
```

### Step 5: Commit and Push

```bash
git add -A
git commit -m "feat(karmada): Add karmada-agent deployments for Pull mode

Signed-off-by: rajsinghtech <raj@tailscale.com>"
git push
```

### Step 6: Verify Agent Registration

After Flux reconciles, verify agents registered:

```bash
# Get Karmada kubeconfig
kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
  -n karmada-system port-forward svc/karmada-apiserver 5443:5443 &

# Check clusters
kubectl --kubeconfig=/tmp/karmada.kubeconfig get clusters

# Should show:
# NAME          VERSION   MODE   READY
# ottawa        v1.x.x    Pull   True
# robbinsdale   v1.x.x    Pull   True
# stpetersburg  v1.x.x    Pull   True
```

## Failover Configuration

Create a PropagationPolicy for automatic failover:

```yaml
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  name: my-app-failover
spec:
  resourceSelectors:
    - apiVersion: apps/v1
      kind: Deployment
      name: my-app
  placement:
    clusterAffinity:
      clusterNames:
        - ottawa
        - robbinsdale
        - stpetersburg
    replicaScheduling:
      replicaDivisionPreference: Weighted
      replicaSchedulingType: Divided
      weightPreference:
        staticWeightList:
          - targetCluster:
              clusterNames:
                - ottawa
            weight: 1
          - targetCluster:
              clusterNames:
                - robbinsdale
            weight: 0
          - targetCluster:
              clusterNames:
                - stpetersburg
            weight: 0
    spreadConstraints:
      - maxGroups: 1
        minGroups: 1
        spreadByField: cluster
  failover:
    application:
      decisionConditions:
        tolerationSeconds: 60
      purgeMode: Gracefully
```

## Testing Failover

See `test-failover/` directory for example resources.

1. **Verify initial placement**:
   ```bash
   kubectl --kubeconfig=/tmp/karmada.kubeconfig get rb -A
   ```

2. **Simulate cluster failure** (cordon nodes):
   ```bash
   kubectl --context=ottawa-k8s-operator.keiretsu.ts.net cordon --all
   ```

3. **Watch failover** (wait ~60 seconds):
   ```bash
   kubectl --kubeconfig=/tmp/karmada.kubeconfig get rb -w
   ```

4. **Restore cluster**:
   ```bash
   kubectl --context=ottawa-k8s-operator.keiretsu.ts.net uncordon --all
   ```

## Troubleshooting

### Agent not registering

Check agent logs:
```bash
kubectl -n karmada-system logs -l app=karmada-agent -f
```

Check if it can reach Karmada API:
```bash
kubectl -n karmada-system exec -it deploy/karmada-agent -- \
  curl -k https://karmada-apiserver.keiretsu.ts.net:5443/healthz
```

### Certificate issues

Verify the secret contains valid certs:
```bash
kubectl -n karmada-system get secret karmada-agent-kubeconfig -o yaml
```

### Cluster shows NotReady

Check cluster conditions:
```bash
kubectl --kubeconfig=/tmp/karmada.kubeconfig describe cluster <name>
```

### View controller logs

```bash
kubectl -n karmada-system logs -l app=karmada-controller-manager -f
```

## Key Resources

- **Cluster**: Represents a registered member cluster
- **PropagationPolicy**: Rules for where workloads go
- **ResourceBinding**: Tracks current placement decisions
- **OverridePolicy**: Cluster-specific configuration overrides

## References

- [Karmada Docs: Cluster Registration](https://karmada.io/docs/userguide/clustermanager/cluster-registration/)
- [Karmada Docs: Pull Mode](https://karmada.io/docs/userguide/clustermanager/working-with-anp/)
- [Karmada Helm Charts](https://github.com/karmada-io/karmada/tree/master/charts)
