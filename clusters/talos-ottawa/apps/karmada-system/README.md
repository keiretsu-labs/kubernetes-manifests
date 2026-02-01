# Karmada Multi-Cluster Setup

Karmada provides multi-cluster workload scheduling with automatic failover.

## Architecture

- **Control Plane**: Ottawa cluster (primary)
- **Member Clusters**: Ottawa, Robbinsdale, St Petersburg
- **Failover Priority**: Ottawa → Robbinsdale → St Petersburg

## Components

The Karmada control plane includes:
- `karmada-apiserver` - API server for Karmada resources
- `karmada-controller-manager` - Manages propagation and failover
- `karmada-scheduler` - Schedules workloads to clusters
- `karmada-webhook` - Admission webhooks
- `karmada-aggregated-apiserver` - Aggregated API server
- `etcd` - Stores Karmada state

## Post-Installation Setup

After the Helm release is deployed, you need to manually join member clusters.

### Step 1: Get Karmada kubeconfig

```bash
# On Ottawa cluster (via Tailscale operator)
kubectl --context=ottawa-k8s-operator.keiretsu.ts.net get secret -n karmada-system karmada-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/karmada.config

# Note: The kubeconfig uses internal cluster DNS (karmada-apiserver.karmada-system.svc.cluster.local:5443)
# For external access, you may need to port-forward:
kubectl --context=ottawa-k8s-operator.keiretsu.ts.net -n karmada-system port-forward svc/karmada-apiserver 5443:5443 &

# Verify it works (from within the cluster or with port-forward)
kubectl --kubeconfig=/tmp/karmada.config get clusters
```

### Step 2: Install karmadactl

```bash
# Download karmadactl
curl -sLO https://github.com/karmada-io/karmada/releases/download/v1.16.2/karmadactl-linux-amd64.tgz
tar -xzf karmadactl-linux-amd64.tgz
sudo mv karmadactl /usr/local/bin/
```

### Step 3: Join Member Clusters (Push Mode)

Push mode is simpler - the control plane pushes workloads to members.

```bash
# Set Karmada context
export KUBECONFIG=/tmp/karmada.config

# Join Ottawa (host cluster) as a member
karmadactl join ottawa \
  --cluster-kubeconfig=$HOME/.kube/config \
  --cluster-context=ottawa-k8s-operator.keiretsu.ts.net

# Join Robbinsdale
karmadactl join robbinsdale \
  --cluster-kubeconfig=$HOME/.kube/config \
  --cluster-context=robbinsdale-k8s-operator.keiretsu.ts.net

# Join St Petersburg
karmadactl join stpetersburg \
  --cluster-kubeconfig=$HOME/.kube/config \
  --cluster-context=stpetersburg-k8s-operator.keiretsu.ts.net

# Verify clusters
kubectl --kubeconfig=/tmp/karmada.config get clusters
```

### Step 4: Deploy Test Failover Application

Apply the test resources:
```bash
kubectl --kubeconfig=/tmp/karmada.config apply -f test-failover/
```

## Failover Configuration

The `PropagationPolicy` in `test-failover/` configures:
- **Cluster Priority**: Ottawa → Robbinsdale → St Petersburg
- **Toleration**: 60 seconds before triggering failover
- **Purge Mode**: Gracefully (waits for new replica before removing old)
- **Single Instance**: Only runs on ONE cluster at a time

## Testing Failover

1. **Verify initial placement**:
   ```bash
   kubectl --kubeconfig=/tmp/karmada.config get rb failover-test-deployment -o yaml
   ```

2. **Simulate Ottawa failure** (cordon all nodes):
   ```bash
   kubectl --context=ottawa-k8s-operator.keiretsu.ts.net cordon --all
   kubectl --context=ottawa-k8s-operator.keiretsu.ts.net delete pod -l app=failover-test
   ```

3. **Watch failover** (wait ~60 seconds):
   ```bash
   kubectl --kubeconfig=/tmp/karmada.config get rb failover-test-deployment -w
   ```

4. **Verify on Robbinsdale**:
   ```bash
   kubectl --context=robbinsdale-k8s-operator.keiretsu.ts.net get pods -l app=failover-test
   ```

5. **Restore Ottawa**:
   ```bash
   kubectl --context=ottawa-k8s-operator.keiretsu.ts.net uncordon --all
   ```

## Key Resources

- **Cluster**: Represents a registered member cluster
- **PropagationPolicy**: Rules for where workloads go
- **ResourceBinding**: Tracks current placement decisions
- **OverridePolicy**: Cluster-specific configuration overrides

## Troubleshooting

### Check cluster health
```bash
kubectl --kubeconfig=/tmp/karmada.config describe cluster ottawa
```

### Check propagation status
```bash
kubectl --kubeconfig=/tmp/karmada.config get rb -A
kubectl --kubeconfig=/tmp/karmada.config describe rb <name>
```

### View Karmada controller logs
```bash
kubectl -n karmada-system logs -l app=karmada-controller-manager -f
```
