# Kubernetes GitOps Infrastructure

Multi-cluster Kubernetes infrastructure managed with FluxCD GitOps. This repository manages three geographically distributed Talos Linux clusters connected via Tailscale mesh networking and Istio multi-cluster service mesh.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Tailscale Mesh                                  │
│                         (keiretsu.ts.net)                                   │
└─────────────────────────────────────────────────────────────────────────────┘
         │                         │                         │
         ▼                         ▼                         ▼
┌─────────────────┐       ┌─────────────────┐       ┌──────────────────┐
│  talos-ottawa   │       │talos-robbinsdale│       │talos-stpetersburg│
│    (Ontario)    │       │   (Minnesota)   │       │    (Florida)     │
│                 │       │                 │       │                  │
│ • 3 nodes       │       │ • Multi-node    │       │ • GPU nodes      │
│ • Thunderbolt   │       │ • Rook-Ceph     │       │ • AI/ML workloads│
│ • Rook-Ceph     │       │ • Primary site  │       │ • KubeRay        │
│ • Home apps     │       │ • Home apps     │       │                  │
└─────────────────┘       └─────────────────┘       └──────────────────┘
         │                         │                         │
         └─────────────────────────┴─────────────────────────┘
                                   │
                  ┌────────────────┴────────────────┐
                  │   Istio Multi-Cluster Mesh      │
                  │   (East-West Gateways)          │
                  └─────────────────────────────────┘
```

## Clusters

| Cluster | Location | Platform | Purpose | Domain |
|---------|----------|----------|---------|--------|
| `talos-ottawa` | Ontario, CA | Talos Linux | Primary homelab, 3-node Thunderbolt mesh | killinit.cc |
| `talos-robbinsdale` | Minnesota, US | Talos Linux | Primary homelab, storage | lukehouge.com |
| `talos-stpetersburg` | Florida, US | Talos Linux | GPU/AI workloads (NVIDIA) | rajsingh.info |

## Directory Structure

```
├── clusters/
│   ├── common/                    # Shared across all clusters
│   │   ├── apps/                  # Common applications (46+ apps)
│   │   ├── bootstrap/flux/        # FluxCD bootstrap configuration
│   │   └── flux/                  # Common Flux kustomizations & repos
│   │       ├── repositories/      # Helm/OCI/Git repositories
│   │       │   ├── helm/          # 80+ HelmRepository definitions
│   │       │   ├── oci/           # OCI repositories
│   │       │   └── git/           # Git repositories
│   │       └── vars/              # Common settings ConfigMap
│   │
│   ├── talos-ottawa/              # Ottawa cluster
│   │   ├── apps/                  # Cluster-specific apps
│   │   ├── bootstrap/talos/       # Talos configuration (talhelper)
│   │   ├── flux/                  # Cluster Flux config & secrets
│   │   └── scripts/               # Utility scripts
│   │
│   ├── talos-robbinsdale/         # Robbinsdale cluster
│   │   ├── apps/
│   │   ├── flux/
│   │   └── talos/
│   │
│   ├── talos-stpetersburg/        # St. Petersburg cluster
│   │   ├── apps/                  # GPU operator, KubeRay, KServe
│   │   ├── bootstrap/talos/
│   │   └── flux/
│   │
│   └── template/                  # App templates
│       ├── app-httproute/         # HTTPRoute + Backend template
│       ├── app-tcproute/          # TCPRoute template
│       └── app-udproute/          # UDPRoute template
│
├── tailscale/                     # Tailscale CI/CD & scripts
├── kubernetes-devcontainer/       # Dev container configuration
└── Makefile                       # Validation commands
```

## Key Infrastructure Components

### FluxCD GitOps

All clusters use FluxCD v2 for GitOps continuous delivery:

- **Source**: Git repository `kubernetes-manifests` (this repo)
- **Kustomizations**: Hierarchical configuration with cluster-specific overrides
- **Variable Substitution**: Settings injected from ConfigMaps/Secrets
- **SOPS Encryption**: GPG-encrypted secrets in git

```yaml
# Configuration hierarchy
clusters/common/flux/vars/common-settings.yaml    # Global settings
clusters/<cluster>/flux/vars/cluster-settings.yaml # Cluster-specific
clusters/<cluster>/flux/vars/cluster-secrets.sops.yaml # Encrypted secrets
```

### SOPS Secret Encryption

All secrets are encrypted with PGP using SOPS:

```yaml
# .sops.yaml
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    pgp: FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5
```

### Istio Multi-Cluster Service Mesh

Istio connects all Talos clusters via east-west gateways:

- **Mesh ID**: `primary`
- **Networks**: Each cluster is a separate network (ottawa, robbinsdale, stpetersburg)
- **East-West Gateways**: Cross-cluster traffic via Tailscale
- **mTLS**: Enabled across all services

```yaml
# clusters/common/apps/istio-system/app/istio-istiod.yaml
meshConfig:
  meshNetworks:
    robbinsdale:
      gateways:
        - service: robbinsdale-istio-eastwestgateway.istio-system
          port: 15443
    ottawa: ...
    stpetersburg: ...
```

### Tailscale Integration

Full Tailscale integration via the official k8s-operator:

- **Operator**: Deployed per-cluster with unique hostnames
- **ProxyClass**: Custom proxy configurations (userspace, accept-routes)
- **Egress Proxies**: Cross-cluster access via ExternalName services
- **Connectors**: Subnet routers for LAN access
- **DNS Config**: In-cluster DNS resolution

```yaml
# ProxyClass examples
- common              # Basic proxy with metrics
- common-accept-routes # Accept advertised routes
- common-userspace    # Unprivileged userspace mode
```

### Monitoring Stack

Prometheus-based monitoring with Grafana visualization:

- **kube-prometheus-stack**: Full monitoring stack (Prometheus, Alertmanager)
- **Grafana Operator**: Declarative dashboard management
- **Grafana Dashboards**: Pre-configured dashboards for all components
- **ServiceMonitors**: Auto-discovery of metrics endpoints

### CNI: Cilium

All Talos clusters use Cilium as the CNI:

- **eBPF-based** networking
- **Hubble UI** for network observability
- **Network Policies** enforcement
- **Service mesh** capabilities (optional)

### Storage

| Cluster | Primary Storage | Secondary |
|---------|----------------|-----------|
| talos-ottawa | Rook-Ceph | SMB (NAS) |
| talos-robbinsdale | Rook-Ceph | SMB (NAS) |
| talos-stpetersburg | local-path | - |

### Gateway API / Envoy Gateway

Modern ingress via Gateway API:

- **Envoy Gateway**: Gateway controller
- **HTTPRoute**: L7 routing with path/header matching
- **TCPRoute/UDPRoute**: L4 routing
- **CDN Integration**: Multi-cluster backends with failover

## Common Applications (clusters/common/apps/)

### Core Infrastructure
- `cert-manager` - TLS certificate management
- `envoy-gateway-system` - Gateway API controller
- `flux-system` - Flux notifications & alerts
- `snapshot-controller` - Volume snapshots
- `spegel` - Container registry P2P mirror
- `local-path-storage` - Local volume provisioner
- `volsync` - PVC replication

### Service Mesh & Networking
- `istio-system` - Istio control plane + east-west gateway
- `tailscale` - Tailscale operator + egress proxies
- `cloudflare` - External DNS + Tunnel
- `core-dns` - DNS customization
- `envoy-ai-gateway-system` - AI gateway

### Monitoring & Observability
- `monitoring` - kube-prometheus-stack
- `grafana` - Grafana operator + dashboards
- `victoria-logs` - Log aggregation
- `hubble-ui` - Cilium network observability
- `blackbox-exporter` - Endpoint probing
- `opencost` - Kubernetes cost monitoring
- `unpoller` - UniFi metrics

### Databases & Storage
- `cnpg-system` - CloudNative PostgreSQL operator
- `dragonfly-operator-system` - Dragonfly (Redis-compatible)
- `mariadb-operator-system` - MariaDB operator
- `pxc-operator-system` - Percona XtraDB Cluster
- `garage` - S3-compatible object storage
- `garage-operator-system` - Garage bucket operator

### Applications
- `ai` - OpenWebUI
- `argocd` - ArgoCD (backup GitOps)
- `coder` - Cloud development environments
- `home` - Homer dashboard, code-server
- `harbor` - Container registry
- `headlamp` - Kubernetes dashboard
- `fluent-bit` - Log shipping

### CI/CD
- `actions-runner-controller` - GitHub Actions runners
- `keda` - Event-driven autoscaling

## Cluster-Specific Applications

### talos-ottawa
- [cilium](https://github.com/cilium/cilium) - CNI with custom config
- [rook-ceph](https://github.com/rook/rook) - Distributed storage cluster
- [immich](https://github.com/immich-app/immich) - Photo management
- `media` - Media management stack
- [gatus](https://github.com/TwiN/gatus) - Status page
- [dockur](https://github.com/dockur/windows) - Docker-in-Kubernetes
- [tuppr](https://github.com/home-operations/tuppr) - Kubernetes controller to upgrade Talos and Kubernetes

### talos-robbinsdale
- `cilium` - CNI with custom config
- `rook-ceph` - Distributed storage cluster
- `1password` - Secret management
- `immich` - Photo management
- `media` - Media management stack
- `home` - Home Assistant
- `homarr` - Home dashboard ([homarr.lukehouge.com](https://homarr.lukehouge.com))
- `typeo` - Typing practice app
- `strimzi` - Kafka cluster

### talos-stpetersburg
- `gpu-operator` - NVIDIA GPU support
- `kuberay` - Ray cluster for distributed ML
- `kserve` - Model serving
- `ai/inference` - ML inference workloads
- `ai/clawd` - Custom AI app

## Prerequisites

### Required Tools

```bash
# Package managers
brew install mise  # or use asdf

# Core tools (install via mise)
mise install kubectl flux sops gpg talhelper talosctl task

# Optional
brew install helm kustomize cilium-cli
```

### GPG Key Setup

```bash
# Import the SOPS PGP key
gpg --import /path/to/sops.asc

# Trust the key
echo "FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5:6:" | gpg --import-ownertrust

# Verify
gpg --list-secret-keys | grep FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5
```

## Bootstrap a New Talos Cluster

See [clusters/talos-ottawa/bootstrap/talos/README.md](clusters/talos-ottawa/bootstrap/talos/README.md) for comprehensive instructions.

### Quick Start

```bash
cd clusters/<cluster-name>

# 1. Generate Talos configs (requires talhelper + sops)
mise run init        # Generate encrypted secrets
mise run genconfig   # Generate node configs

# 2. Apply configs to nodes
mise run apply       # Apply to all nodes
mise run bootstrap   # Bootstrap Kubernetes

# 3. Install Cilium CNI
helm install cilium cilium/cilium -n kube-system -f apps/cilium/app/values.yaml

# 4. Install Flux
kubectl apply --server-side --kustomize clusters/common/bootstrap/flux/
kubectl apply -f flux/config/cluster.yaml

# 5. Wait for reconciliation
flux get ks -A --watch
```

## Adding a New Application

### Cluster-Specific vs Common Apps

- **`clusters/common/apps/`** - Apps deployed across **ALL** clusters. Only put apps here if you want Flux to deploy them everywhere.
- **`clusters/<cluster-name>/apps/`** - Apps deployed only to that specific cluster. Use this for cluster-specific workloads, hardware-dependent apps, or apps that shouldn't run everywhere.

### 1. Create App Directory

```bash
# For apps deployed to ALL clusters:
mkdir -p clusters/common/apps/<namespace>/{app,config}

# For cluster-specific apps:
mkdir -p clusters/<cluster-name>/apps/<namespace>/{app,config}
```

### 2. Create Kustomization

```yaml
# clusters/common/apps/<namespace>/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app-name>
  namespace: flux-system
spec:
  targetNamespace: <namespace>
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./clusters/common/apps/<namespace>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: kubernetes-manifests
  wait: true
  interval: 30m
```

### 3. Create HelmRelease (if using Helm)

```yaml
# clusters/common/apps/<namespace>/app/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app-name>
spec:
  interval: 30m
  chart:
    spec:
      chart: <chart-name>
      version: x.x.x
      sourceRef:
        kind: HelmRepository
        name: <repo-name>
        namespace: flux-system
  values:
    # ... your values
```

### 4. Add to Kustomization

```yaml
# clusters/common/apps/kustomization.yaml
resources:
  - ./<namespace>
```

## Using App Templates

Templates in `clusters/template/` provide reusable patterns:

```bash
# Copy and customize
cp -r clusters/template/app-httproute clusters/common/apps/myapp/routes

# Uses variable substitution:
# ${APP}, ${LOCATION}, ${FAILOVER}, ${APP_PORT}, ${COMMON_DOMAIN}
```

## Common Operations

### Flux Commands

```bash
# Check sync status
flux get ks -A
flux get hr -A

# Force reconciliation
flux reconcile ks cluster -n flux-system
flux reconcile source git kubernetes-manifests -n flux-system

# Suspend/resume
flux suspend ks <name> -n flux-system
flux resume ks <name> -n flux-system
```

### Talos Commands (per-cluster)

```bash
cd clusters/talos-ottawa
mise run health      # Check cluster health
mise run dashboard   # Open Talos dashboard
mise run kubeconfig  # Fetch kubeconfig
```

### Secret Management

```bash
# Encrypt a secret
sops -e secret.yaml > secret.sops.yaml

# Decrypt for viewing
sops -d secret.sops.yaml

# Edit in place
sops secret.sops.yaml
```

### Validation

```bash
# Validate all kustomizations
make validate-kustomize
```

## Networking Reference

### Cluster CIDRs

| Cluster | Pod CIDR | Service CIDR | LB CIDR |
|---------|----------|--------------|---------|
| talos-robbinsdale | 10.1.0.0/16 | 10.0.0.0/16 | 10.50.0.0/16 |
| talos-ottawa | 10.3.0.0/16 | 10.2.0.0/16 | 10.169.0.0/16 |
| talos-stpetersburg | 10.5.0.0/16 | 10.4.0.0/16 | 10.73.0.0/16 |

### Tailscale DNS

Services are accessible at `<hostname>.keiretsu.ts.net`:
- `ottawa-k8s-operator.keiretsu.ts.net`
- `robbinsdale-k8s-operator.keiretsu.ts.net`
- `stpetersburg-k8s-operator.keiretsu.ts.net`

## Links

- [FluxCD Documentation](https://fluxcd.io/docs/)
- [Talos Linux](https://www.talos.dev/latest/)
- [Talhelper](https://github.com/budimanjojo/talhelper)
- [SOPS](https://github.com/getsops/sops)
- [Istio Multi-Cluster](https://istio.io/latest/docs/setup/install/multicluster/)
- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)

## Support

For detailed cluster-specific instructions, see the README files in each cluster's `bootstrap/talos/` directory.
