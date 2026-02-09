# Kubernetes Manifests Repository - Claude Knowledge Base
instead of applying helm or kustomize or yamls use gitops fluxcd
YOU HAVE ACCESS TO POD AND SERVICE IP'S LCOALLY

## Repository Overview

This is a **production GitOps repository** managing multi-cluster Kubernetes infrastructure across three physical locations (Robbinsdale, Ottawa, St. Petersburg) using Flux CD, with extensive Tailscale VPN integration for secure networking and zero-trust access control.

**Repository Structure:**
```
.
├── clusters/           # Multi-cluster GitOps configurations
│   ├── common/        # Shared applications across all clusters
│   ├── talos-robbinsdale/  # Primary production home lab cluster
│   ├── talos-ottawa/       # Media and services cluster
│   ├── talos-stpetersburg/   # AI/ML GPU-accelerated cluster
│   └── template/           # Reusable application templates
├── tailscale/         # Tailscale VPN configuration and automation
├── .github/           # CI/CD workflows and automation scripts
├── .devcontainer/     # Devcontainer configuration
├── .vscode/           # VS Code settings
├── .kuberlr/          # kubectl version manager binaries
└── venv/              # Python virtual environment
```

---

## Clusters Directory (`/clusters`)

### 1. `common/` - Shared Configuration Layer

**Purpose:** Central repository for applications deployed across all clusters

**Key Applications (34 total):**

#### Infrastructure & Platform
- **flux-system** - GitOps engine with monitoring dashboards
- **argocd** - Alternative GitOps tool (runs alongside Flux)
- **cert-manager** - TLS certificate management
- **headlamp** - Kubernetes UI dashboard
- **harbor** - Container registry
- **spegel** - P2P container image distribution

#### Monitoring & Observability
- **monitoring** - Kube-prometheus-stack with Grafana
- **opencost** - Kubernetes cost monitoring
- **hubble-ui** - Cilium network observability (via CNI)

#### Networking & Service Mesh
- **cilium** - CNI with advanced networking features
- **istio-system** - Service mesh
- **envoy-gateway-system** - API gateway
- **envoy-ai-gateway-system** - AI-specific API gateway
- **istio-multicluster-test** - Multi-cluster mesh testing

#### Storage & Databases
- **local-path-storage** - Local volume provisioner
- **cnpg-system** - CloudNativePG operator for PostgreSQL
- **dragonfly-operator-system** - DragonflyDB operator (Redis alternative)
- **snapshot-controller** - Volume snapshot controller
- **volsync** - Volume replication
- **mountpoint-s3-csi** - AWS S3 CSI driver
- **csi-secrets-store** - Secrets Store CSI driver

#### Tailscale Integration (Heavy Focus)
- **tailscale-system** - Operator with DS deployment, peer-relay, testing
- **tailscale-examples** - Sandbox environments (egress, derper, golink, tsdnsproxy, tsddns, tsflow)
- **tailscale** - Additional configurations
- **tailcar** - Custom Tailscale service

#### AI/ML Infrastructure
- **ai** - AI services
- **node-feature-discovery** - Hardware feature detection
- **keda** - Event-driven autoscaling

#### Utilities
- **home** - Homer dashboard, tailscale-gateway, code-server, local-gateway
- **speedtest** - Network speed testing
- **cloudflare** - DNS/CDN management
- **cdn** - Content delivery
- **homer-operator** - Dashboard operator
- **1password** - Secrets management (talos-robbinsdale only)

**Bootstrap Configuration:**
- `/bootstrap/flux/` - Flux installation manifests
- `/flux/` - Repository definitions (Git, Helm, OCI sources)
- `.sops.yaml` - SOPS encryption config (PGP key: FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5)

**Flux Structure Pattern:**
```yaml
# Variable substitution from:
- common-settings (ConfigMap)
- common-secrets (Secret)
- cluster-settings (ConfigMap)
- cluster-secrets (Secret)
- cluster-user-settings (ConfigMap, optional)
- cluster-user-secrets (Secret, optional)
```

---

### 2. `talos-robbinsdale/` - Primary Production Cluster

**Type:** Talos Linux Cluster
**Endpoint:** https://k8s.robbinsdale.local:6443
**Network:**
- Pod CIDR: 10.1.0.0/16
- Service CIDR: 10.0.0.0/16
- CNI: Cilium (kube-proxy disabled)

**5 Nodes with Individual Patches:**
- silver.patch, stone.patch, tank.patch, titan.patch, vault.patch
- base.patch - Shared configuration with Mayastor labels

**Applications:**

#### Home Automation
- **frigate** - NVR with camera monitoring
- **home-assistant** - Home automation platform
- **mqtt** - Mosquitto broker

#### Media Stack
- **jellyfin** - Media streaming server
- **jellyseerr** - Media request management
- **jellystat** - Jellyfin statistics
- **plex** - Alternative media server
- **prowlarr** - Indexer manager
- **radarr** - Movie management
- **readarr** - Book management
- **sonarr** - TV show management
- **bazarr** - Subtitle management
- **audioarr** - Audio content management
- **lidarr** - Music management
- **transmission-*** - Multiple download clients (books, movies, music, tv)
- **immich** - Photo management with Redis
- **homarr** - Homepage dashboard

#### Infrastructure
- **rook-ceph** - Distributed storage cluster
- **cilium** - CNI with generic-device-plugin
- **cert-manager** - TLS certificates
- **csi-driver-smb** - SMB storage integration
- **strimzi** - Kafka operator

#### Operations
- **gatus** - Uptime monitoring with S3 backend
- **speedtest** - Network testing
- **cloudflare** - DNS management
- **tailscale** - VPN integration
- **code-server** - VS Code in browser
- **typeo** - Custom application
- **test** - Testing namespace

**Configuration Files:**
- `/talos/Makefile` - Cluster management commands
- `/talos/patch/schematic.yaml` - Talos image customization
- `/init.sh` - Cluster initialization
- `/jobs/diskspeedtest/` - Performance testing jobs

---

### 3. `talos-ottawa/` - Media & Services Cluster

**Type:** Talos Linux Cluster

**Applications (30+ services):**

#### Complete Media Stack
- **Streaming:** jellyfin, plex
- **Request Management:** jellyseerr, overseerr, wizarr
- **Statistics:** jellystat, tautulli
- **TV Shows:** sonarr-1080p, sonarr-4k, sonarr-anime
- **Movies:** radarr-1080p, radarr-4k, radarr-4kremux, radarr-anime
- **Music:** lidarr
- **Subtitles:** bazarr-1080p, bazarr-4k, bazarr-4kremux, bazarr-anime
- **Download Clients:** qb (qBittorrent), qb-pvt (private), sabnzbd
- **Indexers:** prowlarr, autobrr
- **Utilities:** unmanic (transcoding), tunarr (channel creation), configarr (configuration), feedcord (notifications)

#### Infrastructure
- **rook-ceph** - Ceph storage cluster
- **cilium** - CNI networking
- **csi-driver-smb** - SMB storage
- **gatus** - Uptime monitoring
- **pocket-id** - Identity/authentication
- **dockur** - Container service

**Configuration Files:**
- `/talos/talosconfig` - Cluster configuration
- `/talos/metal-amd64.iso` - Installation ISO
- `/scripts/` - Utility scripts (bond-test, thunderbolt-test, verify-disks)
- `/opnsense/frr.conf` - OPNsense routing
- `/unifi/frr.conf` - UniFi routing
- `/jobs/diskspeedtest/` - Performance testing

---

### 4. `talos-stpetersburg/` - AI/ML Cluster

**Type:** K3s Cluster
**Purpose:** GPU-accelerated AI/ML workloads

**Network Configuration:**
- Pod CIDR: 10.5.0.0/16
- Service CIDR: 10.4.0.0/16
- Max pods: 250
- Disabled: servicelb, traefik, CNI (Cilium installed separately)

**AI/ML Stack:**
- **ai/inference** - Ollama for LLM inference
- **kserve** - Model serving platform (depends on monitoring)
- **kuberay** - Ray cluster for distributed computing
- **pipelines** - ML pipeline orchestration

**GPU Infrastructure:**
- **gpu-operator** - NVIDIA GPU operator with time-slicing config
- **node-feature-discovery** - GPU detection (from common)

**Supporting Services:**
- **cilium** - CNI with advanced features
- **cloudflare** - DNS management

**Bootstrap Files:**
- `/bootstrap/k3s-config.yaml` - K3s server configuration
- `/bootstrap/k3s-install/` - Installation scripts
- `/unifi/frr.conf` - FRR routing configuration

**Flux Configuration:**
- `.sops.yaml` - SOPS encryption (same PGP key as common)
- `flux/apps.yaml` - Main Flux Kustomization

---

### 5. `template/` - Application Templates

Reusable Kustomize templates for new application deployment:

1. **app-httproute/** - HTTP application with Gateway API
   - backend.yaml, httproute.yaml, kustomization.yaml

2. **app-tcproute/** - TCP application
   - backend.yaml, tcproute.yaml, kustomization.yaml

3. **app-udproute/** - UDP application
   - backend.yaml, udproute.yaml, kustomization.yaml

4. **app-pg/** - PostgreSQL database template (placeholder)

---

## Tailscale Directory (`/tailscale`)

### Core Configuration

**`policy.hujson`** - Central ACL policy defining zero-trust network security

**IP Sets by Location:**
- **Robbinsdale:** 192.168.50.0/24, 10.0.0.0/16, 10.1.0.0/16, 10.50.0.0/16, fd7a:115c:a1e0:b1a:0:1::/96
- **Ottawa:** 192.168.169.0/24, 10.2.0.0/16, 10.3.0.0/16, 10.169.0.0/16, fd7a:115c:a1e0:b1a:0:2::/96
- **St. Petersburg:** 192.168.73.0/24, 10.4.0.0/16, 10.5.0.0/16, 10.73.0.0/16, fd7a:115c:a1e0:b1a:0:3::/96

**User Groups:**
- **group:superuser** - kbpersonal@github, LukeHouge@github, rajsinghtech@github
- **group:ottawa** - kbpersonal@github, rajsinghtech@github
- **group:robbinsdale** - LukeHouge@github, rajsinghtech@github
- **group:stpetersburg** - rajsinghtech@github
- **group:kind** - rajsinghtech@github (testing)

**Tags:**
- `tag:infra` - Infrastructure components
- `tag:k8s-operator` - Kubernetes operators (hierarchical ownership)
- `tag:k8s` - General Kubernetes resources
- `tag:k8s-recorder` - SSH session recording
- `tag:robbinsdale`, `tag:ottawa`, `tag:stpetersburg` - Location tags
- `tag:ci` - CI/CD workloads
- `tag:singh360` - Specific access patterns

**Auto-Approvers:**
- Exit node capabilities for tag:k8s
- Route auto-approval for subnet routes at each location
- Service auto-approval for operators and flow services

**SSH Access:**
- Superusers and k8s-tagged devices can SSH everywhere
- **Enforced recording** via tag:k8s-recorder
- Root and non-root user access

**Grants:**
- Self-access for all members
- Cross-location access via subnet routers
- Internet egress through location exit nodes
- **Kubernetes API impersonation:**
  - Superusers/k8s: `system:masters` (full admin)
  - Regular members: `tailnet-readers` (read-only)
- TSIDP admin UI access
- DNS proxy configuration
- Relay capabilities

**Node Attributes:**
- App Connectors (GitHub preset, Cloudflare speed test, location-specific domains)
- Funnel enabled for tag:k8s

---

### Scripts Directory (`/tailscale/scripts/`)

**19 utility scripts:**

#### Authentication & Token Management
- `get-access-token.sh` - OAuth token retrieval
- `exchange-oidc-token.sh` - GitHub Actions OIDC → Tailscale token
- `create-oauth-client.sh` - Create OAuth clients for tags
- `create-auth-key.sh` - Generate ephemeral auth keys

#### Tailnet Management
- `create-tailnet.sh` - Create API-only tailnets (testing)
- `delete-tailnet.sh` - Cleanup test tailnets
- `update-acl.sh` - Push ACL policy updates
- `get-acl.sh` - Retrieve current ACL

#### Device Management
- `get-devices.sh` - List all devices
- `list-devices.sh` - Formatted device listing
- `manage-device.sh` - Device lifecycle operations
- `delete-device.sh` - Remove devices
- `device-connect.sh` - Connection utilities

#### Policy & Configuration
- `convert-hujson.sh` - Python-based HuJSON → JSON converter
- `create-tag-acl.sh` - Create ACL rules for tags
- `policy.json` - Converted policy output

#### Testing & Validation
- `test-workflow-components.sh` - Pre-flight checks for CI/CD
- `validate.sh` - ACL policy validation

---

### CICD Directory (`/tailscale/cicd/`)

**Purpose:** Isolated testing environment for Tailscale operator integration

**Files:**
- `policy.hujson` - Simplified policy for CI testing
- `kind-config.yaml` - Kubernetes-in-Docker cluster config with port mappings (80, 443, 30000)

**Used by:** `.github/workflows/api-tailnet-k8s-test.yml` for E2E testing

---

### Kubernetes Integration

**Operator Deployment (clusters/common/apps/tailscale/):**
- Version: 1.90.8
- API Server Proxy: Enabled with impersonation
- Location-aware naming: `${LOCATION}-k8s-operator`
- Debug logging enabled
- Tags: Location-specific + k8s-operator
- Experimental: Kubernetes API events tracking

**Core Resources:**

1. **Connector** (Subnet Router & App Connector)
   - 3 replicas for HA
   - Advertises: LAN CIDR, Service CIDR, Pod CIDR, LB CIDR, IPv6 4via6 routes
   - Exit node enabled

2. **ProxyClass Definitions**
   - `common` - Basic metrics with ServiceMonitor
   - `common-accept-routes` - Accepts advertised routes

3. **ProxyGroup Configurations**
   - `common-egress` - 3 replicas for outbound
   - `common-ingress` - 3 replicas for inbound
   - `kubernetes-${LOCATION}` - API server access

4. **Egress Services**
   - Cross-cluster Kubernetes API access
   - Services for each cluster operator
   - Tailscale proxy-group for secure communication

5. **Recorder**
   - SSH session recording with UI
   - S3 backend: DigitalOcean Spaces (nyc3.digitaloceanspaces.com)
   - Bucket: tailscale-ssh-recorder-keiretsu

6. **DNSConfig**
   - Custom DNS nameserver deployment
   - LoadBalancer on port 53 (UDP/TCP)
   - Internal IP: `${CLUSTER_LOAD_BALANCER_CIDR}.69.50`

7. **RBAC**
   - `tailnet-readers-view` ClusterRoleBinding
   - Read-only access for Tailscale-authenticated users

**Custom CSI Provider:**
- DaemonSet with custom image: `ghcr.io/rajsinghtech/tailscale/tailscale-csi-provider:dev`
- Secrets Store CSI integration
- Auth key mounting for pods

**Community Applications:**
- **golink** - URL shortener with TSNet, Ceph storage, CSI auth
- **tclip** - Pastebin (TSNet hostname: paste)
- **tsidp** - Identity Provider (custom StatefulSet, K8s secret-based state)

---

## GitHub Directory (`/.github`)

### Workflows (11 total)

#### Tailscale Integration Workflows

**tailscale.yml** - ACL Sync
- Trigger: Push/PR on `tailscale/policy.hujson`
- Deploys ACL on merge, tests on PR
- Uses: `tailscale/gitops-acl-action@v1`

**api-tailnet-k8s-test.yml** - E2E Integration Test
- Trigger: Manual
- GitHub OIDC → Tailscale token exchange
- Creates ephemeral API-only tailnet
- Installs Kind + Tailscale operator
- Verifies registration and connectivity
- Auto-cleanup

**delete-inactive-tailnet-nodes.yml** - Device Cleanup
- Trigger: Manual with inputs (tags, inactive_days, dry_run)
- OIDC authentication
- Tag-based filtering (default: tag:k8s,tag:ottawa)
- Default: 30 days inactivity threshold

**tailscale-full-config-status.yml** - Status Check
- Trigger: Manual
- Quick connectivity test
- Uses: `tailscale/github-action@v4`

**token.yml** - OIDC Token Exchange Demo
- Trigger: Manual
- Educational: demonstrates OIDC flow

#### Claude AI Integration Workflows

**claude.yml** - Claude Code Interactive
- Trigger: Issue/PR comments mentioning @claude
- Interactive AI assistant
- Uses: `anthropics/claude-code-action@v1`
- Permissions: contents:read, pull-requests:read, issues:read, id-token:write

**claude-code-review.yml** - Automated PR Review
- Trigger: PR opened/synchronized
- Reviews: code quality, bugs, performance, security, test coverage
- Restricted tools for safety

**claude-code-analysis.yml** - Advanced Analysis with K8s Access
- Trigger: Push to main, PR opened/synchronized, manual
- Architecture:
  1. GitHub OIDC → Tailscale token
  2. Install Tailscale, connect to network
  3. Configure kubectl via Tailscale
  4. Run Node.js Claude agent with cluster access
  5. Generate structured findings
  6. Comment on PRs
  7. Fail on high-severity issues
- Uses: Custom Node.js scripts with Claude Agent SDK

#### Repository Management

**label-sync.yaml** - Label Sync
- Trigger: Manual or push to `.github/labels.yaml`
- Uses: `EndBug/label-sync@v2`

**release.yaml** - Release Automation
- Trigger: Manual or monthly (1st at midnight)
- Versioning: YYYY.M.P
- Condition: Only for 'onedr0p/cluster-template' repo

**devcontainer.yaml** - Devcontainer Build
- Trigger: Manual, push/PR on `.devcontainer/ci/**`, daily
- Publishes to GHCR
- Platform: linux/amd64

---

### Scripts (`/.github/scripts/claude-agent/`)

**analyze.js** - Full Claude Agent
- Uses Claude Agent SDK for structured queries
- Custom system prompt (security/K8s expertise)
- Tools: Glob, Grep, Read, Bash (kubectl)
- Structured JSON output
- Exit code based on severity

**simple-analyze.js** - Lightweight Version
- Direct Claude API calls (no SDK)
- Basic queries (files + K8s status)
- Simpler, faster analysis

**package.json**
- Dependencies: @anthropic-ai/claude-agent-sdk, axios, zod
- Node: >=18.0.0
- Type: ESM

---

## Other Configuration

### `.devcontainer/`

**devcontainer.json:**
```json
{
  "runArgs": ["--device=/dev/net/tun"],
  "capAdd": ["NET_ADMIN", "NET_RAW", "MKNOD"],
  "features": {
    "ghcr.io/tailscale/codespace/tailscale": {}
  }
}
```
- Enables Tailscale inside devcontainers
- Requires TUN device and network capabilities

---

### `.vscode/`

**settings.json:**
- Associates `.hujson` with JSONC language mode
- JSONC formatting: 2 spaces, no format on save, word wrap
- Renders whitespace for formatting visibility

**extensions.json:**
- Recommends: `vscode.json-language-features`

---

### `.kuberlr/`

**Purpose:** kubectl version manager

**Binary:**
- `darwin-arm64/kubectl1.33.3` (57MB, Apple Silicon)
- .gitignored (line 22 in .gitignore)

---

### `Makefile`

**Targets:**
- `help` - Show available commands
- `validate-kustomize` - Validate all Kustomize builds
  - Iterates through `clusters/talos-robbinsdale/apps/*`
  - Uses `KUBERNETES_VERSION=1.29.0`
  - Enables Helm with `--enable-helm`
  - Exits on validation failure
- `install-deps` - (referenced but not defined)

---

### `.gitignore`

**Key Exclusions:**
- **Secrets:** SOPS private keys (*.private.asc), talsecret.yaml, kubeconfig files, decrypted files (*.dec)
- **Talos:** clusterconfig/, talosconfig, *.iso
- **Terraform:** .terraform*, tfstate, tfvars
- **Hardware:** hardware-info/
- **Test Results:** thunderbolt-results*.txt
- **Claude Docs:** CLAUDE.md (this file)
- **Temporary:** *.tmp, *.bak, *.swp
- **Other:** .DS_Store, venv, charts, next

---

## Architecture Summary

### Multi-Cluster Design
- **3 Physical Locations:** Robbinsdale (MN), Ottawa (ON), St. Petersburg (FL)
- **3 Kubernetes Clusters:** 2 Talos (production), 1 K3s (AI/ML)
- **Overlay Network:** Tailscale WireGuard mesh connecting all sites
- **GitOps Engine:** Flux CD with variable substitution
- **Storage:** Rook-Ceph distributed storage (Talos clusters)

### Networking
- **CNI:** Cilium across all clusters (replaces default CNI, kube-proxy disabled)
- **Service Mesh:** Istio for multi-cluster communication
- **API Gateway:** Envoy Gateway (including AI-specific variant)
- **VPN:** Tailscale with subnet routing, exit nodes, app connectors
- **DNS:** Tailscale MagicDNS + custom DNS proxy for K8s DNS

### Security
- **Zero-Trust:** Tag-based ACLs, no blanket allow rules
- **SSH Recording:** Enforced via tag:k8s-recorder with S3 backend
- **Secrets:** SOPS encryption (GitOps-friendly), 1Password integration
- **TLS:** cert-manager automated certificates
- **Auth:** GitHub SSO, OAuth clients, OIDC workload identity

### Observability
- **Metrics:** Prometheus + Grafana with custom dashboards (including NVIDIA GPU)
- **Network:** Hubble UI (Cilium observability)
- **Uptime:** Gatus monitoring
- **Cost:** OpenCost

### AI/ML
- **Inference:** Ollama (LLMs)
- **Serving:** KServe
- **Distributed:** Ray
- **Pipelines:** ML pipeline orchestration
- **GPU:** NVIDIA GPU Operator with time-slicing

### Automation
- **CI/CD:** 11 GitHub Actions workflows
- **ACL Management:** GitOps-based Tailscale policy deployment
- **Device Lifecycle:** Automated cleanup of inactive devices
- **AI Code Review:** Claude integration with live K8s access via Tailscale
- **Testing:** Ephemeral tailnet creation for E2E tests
- **Releases:** Monthly automated releases
- **Validation:** Pre-merge Kustomize validation

---

## Key Technologies

| Category | Technologies |
|----------|-------------|
| **Kubernetes** | K3s, Talos Linux |
| **GitOps** | Flux CD, ArgoCD |
| **CNI** | Cilium |
| **Service Mesh** | Istio |
| **Storage** | Rook-Ceph, Local Path, SMB CSI, S3 CSI |
| **Databases** | CloudNativePG (PostgreSQL), DragonflyDB (Redis) |
| **Monitoring** | Prometheus, Grafana, Hubble UI, Gatus |
| **VPN** | Tailscale (WireGuard) |
| **Gateway** | Envoy Gateway, Kubernetes Gateway API |
| **Secrets** | SOPS (PGP), 1Password, Secrets Store CSI |
| **Certificates** | cert-manager |
| **AI/ML** | Ollama, KServe, Ray, NVIDIA GPU Operator |
| **Media** | Jellyfin, Plex, Sonarr, Radarr, Prowlarr, qBittorrent |
| **Home Automation** | Home Assistant, Frigate |
| **CI/CD** | GitHub Actions, Claude AI |
| **Container Registry** | Harbor |

---

## Special Features

### 1. Tailscale Deep Integration
- Custom CSI provider for auth key injection
- API server proxy with impersonation
- SSH session recording with S3 backend
- Community apps (golink, tclip, tsidp)
- Cross-cluster K8s API access via Tailscale
- App connectors for application-level routing
- OIDC workload identity for CI/CD (no long-lived secrets)

### 2. AI-Powered Development
- Claude integration in GitHub workflows
- Automated PR reviews
- Live cluster analysis during code review
- Claude can execute kubectl commands via Tailscale
- Structured findings with severity-based failure

### 3. Multi-Cluster GitOps
- Single source of truth for 3 clusters
- Shared common applications
- Cluster-specific overrides via variable substitution
- SOPS-encrypted secrets in Git
- Automated ACL policy deployment

### 4. Enterprise-Grade Security
- Zero-trust networking (tag-based ACLs)
- Enforced SSH session recording
- Workload identity (OIDC) for CI/CD
- Kubernetes API impersonation tied to Tailscale identity
- Secrets never in plaintext in Git

### 5. GPU-Accelerated AI/ML
- Dedicated K3s cluster for AI workloads
- NVIDIA GPU Operator
- Time-slicing for multi-tenant GPU usage
- KServe for model serving
- Ray for distributed computing

---

## Common Patterns

### Flux Application Structure
```
app-name/
├── kustomization.yaml     # App-level Kustomize config
├── ks.yaml               # Flux Kustomization spec
├── namespace.yaml        # Namespace definition
├── app/                  # Application manifests
│   ├── helmrelease.yaml  # Helm chart deployment
│   └── kustomization.yaml
└── config/               # ConfigMaps, Secrets
    └── kustomization.yaml
```

### Variable Substitution in Flux
```yaml
postBuild:
  substituteFrom:
    - kind: ConfigMap
      name: common-settings
    - kind: Secret
      name: common-secrets
    - kind: ConfigMap
      name: cluster-settings
      optional: true
    - kind: Secret
      name: cluster-secrets
      optional: true
```

**CRITICAL: `$` characters in manifests get mangled by Flux envsubst.** Flux uses drone/envsubst which interprets bare `$` as variable references (e.g. `$2y` in a bcrypt hash → empty string). If a value contains `$` characters (bcrypt hashes, regex, shell expressions), it MUST be stored in a Secret/ConfigMap and injected via `${VAR}` substitution. envsubst is single-pass — `$` in the replacement value of `${VAR}` is NOT re-processed.

### SOPS Encryption
- PGP Key: FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5
- Configuration: `.sops.yaml` in cluster directories
- Encrypted files: `*.sops.yaml`
- Flux decrypts automatically via `sops-gpg` secret

### Tailscale Operator Resources
- **Connector** - Subnet router + app connector (3 replicas)
- **ProxyClass** - Defines proxy behavior
- **ProxyGroup** - Scalable proxy pools (egress/ingress)
- **Recorder** - SSH session recording
- **DNSConfig** - Custom DNS nameserver

---

## Important Notes

### Security
1. **NEVER commit:** SOPS private keys, kubeconfig files, talsecret.yaml, decrypted files
2. **Always encrypt:** Cluster secrets using SOPS before committing
3. **SSH recording:** All privileged access is recorded to S3
4. **OIDC preferred:** Use workload identity for CI/CD (no static secrets)

### Operations
1. **GitOps-first:** All changes should be committed to Git, not applied directly
2. **Testing:** Use ephemeral tailnets for integration testing
3. **Validation:** Run `make validate-kustomize` before committing
4. **ACL changes:** Test in PR before merging (auto-tested by GitHub Actions)

### Tailscale
1. **Tag hierarchy:** k8s-operator > infra > superuser
2. **Auto-approvers:** Routes/exit nodes auto-approved for tag:k8s
3. **Recording enforced:** Cannot SSH without going through recorder
4. **Ephemeral keys:** Use short-lived auth keys for testing

### Clusters
1. **Robbinsdale:** Primary production (5 nodes, Rook-Ceph, home automation)
2. **Ottawa:** Media-focused (30+ *arr stack apps, Rook-Ceph)
3. **St. Petersburg:** AI/ML only (GPU operator, KServe, Ray)

### Adding a New Helm App to Common

**Checklist:**
1. Create `clusters/common/flux/repositories/helm/<name>.yaml` (HelmRepository)
2. Add it to `clusters/common/flux/repositories/helm/kustomization.yaml`
3. Create app directory: `clusters/common/apps/<name>/`
   - `namespace.yaml` — with `kustomize.toolkit.fluxcd.io/prune: disabled`
   - `ks.yaml` — Flux Kustomization pointing to `./app` path
   - `kustomization.yaml` — references `namespace.yaml` and `ks.yaml`
   - `app/helmrelease.yaml` — HelmRelease with chart spec
   - `app/httproute.yaml` — if exposing via Gateway API
   - `app/kustomization.yaml` — sets namespace, lists resources

**Gateway/HTTPRoute gotchas:**
- Check what hostnames the target gateway accepts before creating an HTTPRoute: `kubectl get gateway <name> -n home -o jsonpath='{.spec.listeners[*].hostname}'`
- Common gateways (`ts`, `private`, `public`) are in the `home` namespace and accept `*.${CLUSTER_DOMAIN}` (e.g. `*.killinit.cc` for Ottawa)
- `${COMMON_DOMAIN}` (rajsingh.info) is NOT routable through cluster gateways — use `${CLUSTER_DOMAIN}` for HTTPRoutes
- If HTTPRoute shows `NoMatchingListenerHostname` in status, the hostname doesn't match any gateway listener

**kubectl contexts:**
- Ottawa: `kubernetes-ottawa.keiretsu.ts.net`
- Use `kubectl patch` to test changes live without waiting for Flux (remember `kubectl apply` can't resolve Flux `${VARIABLE}` substitutions)

---

## Quick Reference Commands

### Flux
```bash
# Check Flux status
flux get all -A

# Reconcile specific app
flux reconcile kustomization <app-name> -n flux-system

# Suspend reconciliation
flux suspend kustomization <app-name> -n flux-system
```

### Tailscale
```bash
# Get access token (OAuth)
./tailscale/scripts/get-access-token.sh

# List devices
./tailscale/scripts/list-devices.sh

# Update ACL
./tailscale/scripts/update-acl.sh

# Validate ACL
./tailscale/scripts/validate.sh
```

### Kubernetes
```bash
# Validate Kustomize builds
make validate-kustomize

# Apply specific app (don't do this, use GitOps!)
kubectl apply -k clusters/talos-robbinsdale/apps/<app-name>/
```

### SOPS
```bash
# Encrypt file
sops --encrypt --in-place <file>.yaml

# Decrypt file (view only)
sops --decrypt <file>.sops.yaml

# Edit encrypted file
sops <file>.sops.yaml
```

---

## Recent Changes (from git history)

- Added tag:singh360 with self-access grant
- Added tag:ci for CI/CD workloads
- Tested infra tag capabilities
- Standardized tailnet creation workflow
- Refined relay capabilities
- Cleaned up commented UDM rules
- Currently modifying: tailscale/policy.hujson (unstaged)

## Recent Cleanup (2025-11-22)

**Completed:**
- Fixed `.gitignore` to include `venv/` and match both `CLAUDE.md` and `claude.md`
- Removed 3 empty directories (clusters/template/app-pg, clusters/talos-stpetersburg/apps/pipelines/app, clusters/talos-robbinsdale/apps/home/app/code-server)
- Standardized namespace.yaml formatting across 9 files (added `---` document separator, removed trailing commented ArgoCD annotations)
- Added comprehensive README.md files to 3 key directories:
  - clusters/template/README.md - Application template usage guide
  - clusters/common/README.md - Shared applications documentation
  - tailscale/README.md - Tailscale integration guide (comprehensive)
- **Standardized all 219 kustomization.yaml files** across repository:
  - Fixed 2 files with incorrect field order (kind: before apiVersion:)
  - Fixed 3 files with incorrect indentation
  - Added `---` separator to 29 files
  - Added `kind: Kustomization` to 9 files
  - Removed empty lines after `kind:` from 16 files
  - **Total: 39 files modified** for consistency

**Skipped (intentional):**
- Commented code in Rook-Ceph configs - Kept for documentation/example value
- HTTP links in manifests - Many are internal services, not security issues

---

## tsdb Database Connector (Tailscale)

### Deployment
- **Ottawa:** `clusters/talos-ottawa/apps/media/app/tsdb/` (in media namespace)
- Deployed as StatefulSet with PVC for tsnet state (`/data/tsdb`)
- Image: `ghcr.io/tailscale/tsdb:latest`
- Runs as root (`runAsUser: 0`) - required for tsnet state directory creation
- Uses `serviceAccountName: default` (not tailscale SA - tsdb manages its own auth via OAuth)

### Config Structure (HuJSON)
Config MUST have three nested sections - flat configs silently fail:
```json
{
  "tailscale": { "hostname": "...", "state_dir": "...", "tags": [...], "client_id": "...", "client_secret": "..." },
  "connector": { "admin_port": 8080, "log_level": "info" },
  "databases": { "<db-key>": { "engine": "postgres", "host": "...", "port": 5432, "ca_file": "...", "admin_user": "...", "admin_password": "..." } }
}
```
- OAuth creds (`client_id`/`client_secret`) MUST be in the config, not env vars, for tags to work
- `ca_file` is REQUIRED - cannot be omitted
- Flux variable substitution works in the ConfigMap (`${LOCATION}`, `${TS_OAUTH_CLIENT_ID}`, etc.)

### CA Certificate Handling
- tsdb needs the database server's CA cert at `ca_file` path
- CNPG self-signed CA is in secret `<cluster>-ca` (e.g., `jellystat-postgres-ca`)
- **Cross-namespace problem:** if tsdb and DB are in different namespaces, can't mount the CA secret
- **Solution:** deploy tsdb in the SAME namespace as the database so it can mount the CA secret directly
- CNPG CA rotates ~every 90 days - same-namespace mounting handles this automatically

### ACL Grant (tailscale.com/cap/databases)
**CRITICAL: No wildcard support.** The tsdb code (`internal/relay_base.go:hasAccess`) does EXACT string matching:
- `roles` = actual postgres **usernames** (e.g., `["postgres", "app"]`), NOT abstract roles
- `databases` = actual postgres **database names** (e.g., `["postgres", "app"]`)
- `"*"` is treated as a literal string, not a wildcard

Correct grant format:
```json
"tailscale.com/cap/databases": [{
  "<db-key>": {
    "access": [{"databases": ["postgres", "app"], "roles": ["postgres", "app"]}],
    "engine": "postgres"
  }
}]
```
- `<db-key>` must match the key in `databases` section of tsdb config
- Grant can be merged into existing grant blocks (e.g., with cap/relay, cap/kubernetes)
- Feature requires enablement on the tailnet (behind feature flag `database-capability`)

### CNPG Integration Notes
- CNPG `enableSuperuserAccess: true` creates a superuser secret, but may fail if CNPG is stuck
- If superuser secret is missing, set password manually: `ALTER USER postgres PASSWORD '...'`
- Barman Cloud plugin TLS errors can block CNPG reconciliation - restart both `barman-cloud` and `cnpg-cloudnative-pg` deployments in cnpg-system
- Stuck backups (empty phase) also block reconciliation - delete them

### Tailscale-www Doc Improvements Needed
Docs at: `tailscale-www/nextjs/src/app/docs/_content/features/database-connectors/index.mdx`
1. **roles field is misleading:** docs say "database roles" with example `["viewer", "writer"]` but code matches against postgres USERNAME (`sess.targetUser`). Should say "database usernames" or "database users that callers can connect as"
2. **No wildcard documentation:** docs don't mention that `*` doesn't work as a wildcard. Should explicitly state exact matching only
3. **databases field:** same issue - should clarify these are literal database names, no patterns
4. **ca_file in Kubernetes:** no guidance on cross-namespace cert access. Should recommend deploying tsdb in same namespace as the database
5. **Config structure:** minimal example only shows `databases` section but tsdb silently fails without nested `tailscale`/`connector` sections. Should warn about this
6. **OAuth vs authkey:** docs don't mention that OAuth creds must be in the config file (not env vars) for tags to propagate to per-database tsnet servers

### Related Code Locations
- tsdb source: `/Users/rajsingh/Documents/GitHub/tsdb/`
- Capability definition: `tsdb/pkg/cap.go` (`PeerCapabilityTSDB`)
- Access check: `tsdb/internal/relay_base.go` (`hasAccess` method, ~line 443)
- WhoIs capability extraction: `tsdb/internal/relay_base.go` (`getClientIdentity`, ~line 409)
- Control plane validation: `corp/control/policy/tsdb.go` (`verifyTSDBGrant`)
- Feature flag: `corp/control/feature/feature.go` (`DatabaseCapability`, added 2025-11-17)

---

## Related Repositories (referenced in workflows)

- **tailscale** - `/Users/rajsingh/Documents/GitHub/tailscale`
- **corp** - `/Users/rajsingh/Documents/GitHub/corp`
- **tailscale-client-go-v2** - `/Users/rajsingh/Documents/GitHub/tailscale-client-go-v2`
- **tailscale-www** - `/Users/rajsingh/Documents/GitHub/tailscale-www`
- **rook** - `/Users/rajsingh/Documents/GitHub/rook`

---

## Future Enhancements (from TODOs in README)

- Document image update process (ArgoCD Image Updater)
- Complete app-pg template

---

**End of Knowledge Base**

### Standalone Egress
- Service detection: `cmd/k8s-operator/svc.go:118` — skips ProxyGroup-annotated services
- Headless service creation: `cmd/k8s-operator/sts.go:368-386` — `ClusterIP: "None"` with pod selector
- ExternalName rewrite: `cmd/k8s-operator/svc.go:313-325` — points at headless svc FQDN
- Blanket DNAT: `cmd/containerboot/main.go:613-618` → `installEgressForwardingRule`
- DNAT rule: `util/linuxfw/nftables_runner.go:179-199` → `DNATNonTailscaleTraffic` (no port matching)
- Rule stability: only reinstalled when `ipsHaveChanged` (`main.go:613`)