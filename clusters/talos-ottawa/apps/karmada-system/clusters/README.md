# Karmada Member Cluster Registration

This directory contains the manifests and scripts needed to register member clusters with Karmada.

## Architecture

```
                     ┌─────────────────────────────┐
                     │   Karmada Control Plane     │
                     │   (Ottawa Cluster)          │
                     │                             │
                     │  ┌───────────────────────┐  │
                     │  │  karmada-apiserver    │  │
                     │  │  (internal API)       │  │
                     │  └───────────┬───────────┘  │
                     │              │              │
                     │  ┌───────────▼───────────┐  │
                     │  │  Cluster CRs          │  │
                     │  │  - ottawa             │  │
                     │  │  - robbinsdale        │  │
                     │  │  - stpetersburg       │  │
                     │  └───────────────────────┘  │
                     └─────────────────────────────┘
                                   │
                    Push Mode      │
                    (workloads)    │
                                   ▼
        ┌──────────────────────────────────────────────────┐
        │                                                  │
   ┌────▼────┐         ┌──────────┐         ┌─────────────▼┐
   │ Ottawa  │         │Robbinsdale│        │St Petersburg │
   │ Cluster │         │ Cluster   │        │  Cluster     │
   │         │         │           │        │              │
   │ karmada-│         │ karmada-  │        │ karmada-     │
   │ cluster │         │ cluster   │        │ cluster      │
   │ (ns)    │         │ (ns)      │        │ (ns)         │
   └─────────┘         └───────────┘        └──────────────┘
```

## Why Not Pure GitOps?

Karmada runs its own API server separate from the host cluster. Resources like `Cluster` CRs and their associated secrets must be applied to the **Karmada API server**, not the host cluster's Kubernetes API.

Flux manages the host cluster, so we need a bootstrap process to:
1. Create service accounts on each member cluster
2. Create secrets with tokens in the Karmada API
3. Create Cluster CRs in the Karmada API

## Files

| File | Purpose |
|------|---------|
| `member-cluster-rbac.yaml` | ServiceAccount and ClusterRoleBinding for each member cluster |
| `cluster-*.yaml` | Cluster CR definitions for Karmada |
| `bootstrap.sh` | Automated registration script |

## Registration Process

### Option 1: Automated (Recommended)

Run the bootstrap script:

```bash
# Register all clusters
./bootstrap.sh

# Register a single cluster
./bootstrap.sh ottawa
```

The script will:
1. Fetch the Karmada kubeconfig
2. Start a port-forward to the Karmada API
3. For each cluster:
   - Apply RBAC (ServiceAccount with cluster-admin)
   - Extract the service account token
   - Create secrets in Karmada's namespace
   - Create the Cluster CR
   - Verify the cluster becomes Ready

### Option 2: Manual

If you prefer manual steps:

1. **Apply RBAC to each member cluster:**
   ```bash
   for ctx in ottawa robbinsdale stpetersburg; do
     kubectl --context=${ctx}-k8s-operator.keiretsu.ts.net apply -f member-cluster-rbac.yaml
   done
   ```

2. **Get the Karmada kubeconfig:**
   ```bash
   kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
     get secret -n karmada-system karmada-kubeconfig \
     -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/karmada.config
   ```

3. **Port-forward to Karmada API:**
   ```bash
   kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
     -n karmada-system port-forward svc/karmada-apiserver 5443:5443 &
   
   # Update kubeconfig to use localhost
   sed -i 's|server: https://karmada-apiserver.karmada-system.svc.cluster.local:5443|server: https://127.0.0.1:5443|' /tmp/karmada.config
   ```

4. **Create namespace in Karmada:**
   ```bash
   kubectl --kubeconfig=/tmp/karmada.config create namespace karmada-cluster
   ```

5. **For each cluster, create secrets:**
   ```bash
   CLUSTER=ottawa
   CTX=ottawa-k8s-operator.keiretsu.ts.net
   
   # Get token
   TOKEN=$(kubectl --context=$CTX get secret karmada-controller-token \
     -n karmada-cluster -o jsonpath='{.data.token}' | base64 -d)
   
   # Get CA
   CA=$(kubectl --context=$CTX get configmap kube-root-ca.crt \
     -n kube-system -o jsonpath='{.data.ca\.crt}')
   
   # Create secret
   kubectl --kubeconfig=/tmp/karmada.config create secret generic ${CLUSTER}-kubeconfig \
     -n karmada-cluster \
     --from-literal=token="$TOKEN" \
     --from-literal=caBundle="$CA"
   ```

6. **Apply Cluster CRs:**
   ```bash
   kubectl --kubeconfig=/tmp/karmada.config apply -f cluster-ottawa.yaml
   kubectl --kubeconfig=/tmp/karmada.config apply -f cluster-robbinsdale.yaml
   kubectl --kubeconfig=/tmp/karmada.config apply -f cluster-stpetersburg.yaml
   ```

7. **Verify:**
   ```bash
   kubectl --kubeconfig=/tmp/karmada.config get clusters
   ```

## Cluster Configuration

Each cluster is registered with:

| Cluster | Region | Zone | API Endpoint |
|---------|--------|------|--------------|
| ottawa | us-east | ottawa | ottawa-k8s-operator.keiretsu.ts.net |
| robbinsdale | us-central | robbinsdale | robbinsdale-k8s-operator.keiretsu.ts.net |
| stpetersburg | us-south | stpetersburg | stpetersburg-k8s-operator.keiretsu.ts.net |

### TLS Configuration

We use `insecureSkipTLSVerification: true` because:
- The Tailscale k8s-operator acts as a proxy
- It handles TLS termination with its own certificate
- The underlying cluster CA is different from what Tailscale presents

## Troubleshooting

### Cluster not becoming Ready

Check the Karmada controller logs:
```bash
kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
  -n karmada-system logs -l app=karmada-controller-manager -f
```

### Token errors

Verify the service account token exists:
```bash
kubectl --context=<cluster>-k8s-operator.keiretsu.ts.net \
  get secret karmada-controller-token -n karmada-cluster -o yaml
```

### Connection refused

Ensure the Tailscale k8s-operator is running on the member cluster:
```bash
kubectl --context=<cluster>-k8s-operator.keiretsu.ts.net \
  get pods -n tailscale
```
