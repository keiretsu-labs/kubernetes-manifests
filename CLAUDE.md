# Kubernetes Manifests Repository - Claude Knowledge Base
instead of applying helm or kustomize or yamls use gitops fluxcd
YOU HAVE ACCESS TO POD AND SERVICE IP'S LOCALLY

**kubeconfig:** `/workspace/kubernetes-manifests/.kube/config` is a working kubeconfig for all three clusters (ottawa, robbinsdale, stpetersburg). Use `KUBECONFIG=/workspace/kubernetes-manifests/.kube/config kubectl` to interact with the live clusters over Tailscale. Always check this file before assuming no cluster access.

## Repository Overview

This is a **production GitOps repository** managing multi-cluster Kubernetes infrastructure across three physical locations (Robbinsdale, Ottawa, St. Petersburg) using Flux CD, with extensive Tailscale VPN integration for secure networking and zero-trust access control.

**Repository Structure:**
```
.
├── kubernetes/         # PRIMARY app tree (base + per-location overlays) — see below
│   ├── apps/
│   │   ├── base/<ns>/<app>/     # ALL real manifests, exactly once
│   │   ├── ottawa/<ns>/         # thin pointer files (Flux Kustomization CRs → base)
│   │   ├── robbinsdale/<ns>/
│   │   └── stpetersburg/<ns>/
│   └── components/     # kustomize components shared across apps
├── clusters/           # Bootstrap + shared config layer (NOT app manifests)
│   ├── common/        # Flux sources (repositories), shared vars (common-settings/secrets)
│   ├── talos-robbinsdale/  # per-cluster flux config + talos bootstrap
│   ├── talos-ottawa/       # per-cluster flux config + talos bootstrap
│   └── talos-stpetersburg/
├── tailscale/         # Tailscale VPN policy + automation scripts
├── docs/              # Operational runbooks
├── garage-webadmin/   # Custom Garage S3 web admin image
├── .github/           # CI/CD workflows
├── .devcontainer/     # Devcontainer configuration
└── venv/              # Python virtual environment
```

> **Layout note (migration completed June 2026):** apps used to live under
> `clusters/*/apps/<ns>/<app>/`. They were all re-parented into the
> `kubernetes/` tree. `clusters/` no longer holds workloads — only the Flux
> bootstrap chain, shared Helm/OCI/Git `repositories`, and the
> `common-settings`/`cluster-settings` substitution vars. See
> `kubernetes/README.md` for the authoritative description and the historical
> two-PR move process.

---

## The `kubernetes/` Tree — App Layout (PRIMARY)

All application manifests live under `kubernetes/apps/`. Read
`kubernetes/README.md` for the canonical description.

```
kubernetes/apps/
├── base/<namespace>/<app>/     # real manifests, exactly once (verbatim)
│                               # often split into <app>-<location> variants
│                               # (e.g. media/media-ottawa, media/media-robbinsdale)
├── ottawa/<namespace>/         # per-location overlay = thin pointers
├── robbinsdale/<namespace>/
└── stpetersburg/<namespace>/
    ├── kustomization.yaml      # lists the pointer files (+ namespace.yaml when owned here)
    └── <app>.yaml              # a Flux Kustomization CR whose spec.path → base
```

**How it reconciles (bootstrap chain lives in `clusters/`):**
- `clusters/talos-<location>/flux/config/cluster.yaml` defines:
  - `GitRepository/kubernetes-manifests` — the single Git source (only paths
    `/clusters/common`, `/clusters/talos-<location>`, `/kubernetes` are included)
  - `cluster` Kustomization → `./clusters/talos-<location>/flux` (loads
    `cluster-settings` ConfigMap + `cluster-secrets` Secret)
  - `common-cluster` Kustomization → `./clusters/common/flux` (Helm/OCI/Git
    `repositories` + `common-settings`/`common-secrets`)
  - **`kubernetes-apps` Kustomization → `./kubernetes/apps/<location>`** — the
    app root. It injects SOPS decryption + the `substituteFrom`
    common-settings/common-secrets stack into every child pointer (this replaced
    the old `common-apps` parent).
- Each pointer `<app>.yaml` is a `kustomize.toolkit.fluxcd.io/v1` Kustomization
  with `spec.path: ./kubernetes/apps/base/<ns>/<app>[-<location>]`,
  `sourceRef: kubernetes-manifests`, optional `dependsOn`, and per-app
  `postBuild.substitute` overrides.

**Deploy-to-some-clusters** = the pointer file exists only in those location
overlay trees. An app in `base/` with no pointer anywhere is not deployed.

---

## Clusters Directory (`/clusters`) — Bootstrap & Shared Config

`clusters/` no longer contains workloads. It holds:

### `common/`
- `flux/repositories/` — Helm, OCI, and Git sources referenced by HelmReleases
- `flux/vars/` — `common-settings` ConfigMap, `common-secrets` (SOPS)
- `bootstrap/flux/` — Flux install kustomization + bootstrap secret
- `scripts/` — helper scripts
- `.sops.yaml` — SOPS config (PGP key FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5)
- (a couple of apps — `home`, `searxng` — may still linger here; new apps go in `kubernetes/`)

### `talos-<location>/` (ottawa, robbinsdale, stpetersburg)
- `flux/config/cluster.yaml` — GitRepository + the `cluster`/`common-cluster`/`kubernetes-apps` parent Kustomizations
- `flux/vars/` — `cluster-settings` ConfigMap, `cluster-secrets` (SOPS)
- `bootstrap/` — Talos (talhelper `talconfig.yaml`, patches, ISO) — see Talos section below
- `unifi/`, `opnsense/` (Ottawa) — FRR routing configs
- `jobs/` — one-off jobs (e.g. diskspeedtest)

---

## Application Inventory (by namespace under `kubernetes/apps/base/`)

Not every app runs on every cluster — deployment is controlled by which
location overlay carries the pointer. Notable namespaces/apps:

**Platform & GitOps:** flux-system, argocd, open-cluster-management (+ agent —
OCM hub/spoke replaced Karmada), kro-system, external-secrets, cert-manager,
spegel, tuppr (Talos upgrades), homer-operator, tailgate-operator-system

**Networking / mesh / gateway:** kube-system (Cilium), hubble-ui,
envoy-gateway-system, envoy-ai-gateway-system, k8gb (GSLB DNS), spiderpool,
lan, border0, cloudflare

**Storage & DB:** rook-ceph, garage + garage-operator-system (S3),
local-path-storage, snapshot-controller, csi-addons, csi-driver-smb,
cnpg-system (Postgres), dragonfly-operator-system, clickhouse (+ operator),
velero (backups)

**Observability:** monitoring (kube-prometheus-stack), mimir, tempo (+ operator),
victoria-logs, fluent-bit, gatus, kener, opencost

**Registry / CI:** zot (OCI registry — replaced Harbor), forgejo, woodpecker,
arc-systems (GitHub Actions runners), k6-operator-system

**Media (base/media/media-<location>):** jellyfin, plex, sonarr/radarr/lidarr/
readarr/bazarr/prowlarr, transmission-*, sabnzbd, qb, overseerr, jellyseerr,
tautulli, jellystat, autobrr, wizarr, maintainerr, jellyswarrm, etc.

**Home / apps:** home (Homer, gateways, code-server), home-assistant, immich,
teslamate, hermes, firecrawl, searxng, tinyauth-egress, auth, speedtest

**AI/ML (mostly stpetersburg):** ai, agents, agent-sandbox, gpu-operator,
node-feature-discovery, k8s-gpu-dra-driver, rdma-shared-dp, lws-system,
tailbench, bhaiya (ottawa)

**Tailscale:** tailscale-system (operator), tailscale, tailscale-examples,
gvisor, strimzi

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

**Operator Deployment (`kubernetes/apps/base/tailscale-system/tailscale-system-app/`):**
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

**Targets** (render-test with [`flate`], per-cluster from `clusters/<cluster>/flux/config`):
- `help` - Show available commands (default target)
- `test` - Render-test all three clusters (`flate test all`); exits on failure
- `test-<cluster>` - Render-test one cluster, e.g. `make test-talos-ottawa`
- `diff` - Show rendered diff vs `origin/main` for all clusters (`flate diff all`)

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
- **Secrets:** SOPS encryption (GitOps-friendly)
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
| **Secrets** | SOPS (PGP), Secrets Store CSI |
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

### Flux Application Structure (base + overlay)
```
kubernetes/apps/base/<ns>/<app>/     # real manifests, exactly once
├── kustomization.yaml               # sets namespace, lists resources
├── helmrelease.yaml                 # Helm chart (or raw manifests)
├── httproute.yaml                   # optional, Gateway API
└── namespace.yaml                   # only if this app owns the namespace

kubernetes/apps/<location>/<ns>/      # per-cluster overlay (pointers)
├── kustomization.yaml               # lists <app>.yaml (+ namespace.yaml if owned here)
└── <app>.yaml                       # Flux Kustomization CR, spec.path → base/<ns>/<app>
```
The `<app>.yaml` pointer is what carries `dependsOn`, per-app
`postBuild.substitute`, and `targetNamespace`. The `kubernetes-apps` parent
injects the shared `substituteFrom` stack + SOPS decryption into every pointer.

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
3. **Validation:** Run `make test` (flate render) before committing; `make diff` to preview rendered changes vs `origin/main`
4. **ACL changes:** Test in PR before merging (auto-tested by GitHub Actions)

### Tailscale
1. **Tag hierarchy:** k8s-operator > infra > superuser
2. **Auto-approvers:** Routes/exit nodes auto-approved for tag:k8s
3. **Recording enforced:** Cannot SSH without going through recorder
4. **Ephemeral keys:** Use short-lived auth keys for testing

### Clusters
1. **Ottawa:** Primary production cluster (media, services, databases, Rook-Ceph)
2. **Robbinsdale:** Production home lab (home automation, Rook-Ceph)
3. **St. Petersburg:** AI/ML only (GPU operator, KServe, Ray)

### Adding a New App (base + overlay model)

New apps are created directly in `kubernetes/apps/` — no migration, no
`clusters/*/apps/` anymore. See `kubernetes/README.md`.

**Checklist:**
1. If it needs a new Helm chart source, add the HelmRepository under
   `clusters/common/flux/repositories/helm/<name>.yaml` and list it in that
   dir's `kustomization.yaml` (sources still live in `clusters/common`).
2. Create the base: `kubernetes/apps/base/<ns>/<app>/` (often
   `<app>/<app>-<location>/` if config differs per cluster)
   - `helmrelease.yaml` (or raw manifests) — the real workload
   - `httproute.yaml` — if exposing via Gateway API
   - `kustomization.yaml` — sets namespace, lists resources
   - `namespace.yaml` — only if this app owns the namespace; keep
     `kustomize.toolkit.fluxcd.io/prune: disabled`
3. Add the pointer per target location: `kubernetes/apps/<location>/<ns>/<app>.yaml`
   — a Flux `kustomize.toolkit.fluxcd.io/v1` Kustomization with
   `spec.path: ./kubernetes/apps/base/<ns>/<app>[-<location>]`,
   `sourceRef.name: kubernetes-manifests`, and any `postBuild.substitute` /
   `dependsOn` it needs. The CR `metadata.name` is the app's identity.
4. List the pointer (and `namespace.yaml` if owned here) in
   `kubernetes/apps/<location>/<ns>/kustomization.yaml`.
5. Deploying to only some clusters = only create the pointer in those location
   trees. Validate with `make test` / the flate render before merging.

**Gateway/HTTPRoute gotchas:**
- Check what hostnames the target gateway accepts before creating an HTTPRoute: `kubectl get gateway <name> -n home -o jsonpath='{.spec.listeners[*].hostname}'`
- Common gateways (`ts`, `private`, `public`) are in the `home` namespace and accept `*.${CLUSTER_DOMAIN}` (e.g. `*.killinit.cc` for Ottawa)
- The `private` gateway now also accepts `*.${COMMON_DOMAIN}` (e.g. `*.keiretsu.top`) — but the `public` gateway is the one with the full set of `*.keiretsu.top` listeners
- `${COMMON_DOMAIN}` (keiretsu.top) IS routable through the `public` and `private` gateways (has `*.keiretsu.top` listeners with the `wildcard-keiretsu-top` TLS secret)
- If HTTPRoute shows `NoMatchingListenerHostname` in status, the hostname doesn't match any gateway listener

**DNS gotchas — CRITICAL:**
- `${CLUSTER_DOMAIN}` hostnames (e.g. `*.killinit.cc`) get DNS automatically via external-dns watching HTTPRoutes/Gateway annotations
- `${COMMON_DOMAIN}` hostnames (e.g. `*.keiretsu.top`) do NOT get DNS automatically. The `keiretsu.top` external-dns only sources from DNSEndpoint CRDs with label `dns-target=cloudflare` — it does NOT watch HTTPRoutes
- **When adding an HTTPRoute with a `${COMMON_DOMAIN}` hostname, you MUST also add a CNAME entry** in `kubernetes/apps/base/k8gb/k8gb-common/config/cnames.yaml`:
  - For Ottawa-only apps: target `"ottawa.${COMMON_DOMAIN}"` with `cloudflare-proxied: "false"`
  - For multi-cluster/k8gb apps: target `"<name>.cdn.${COMMON_DOMAIN}"` with `cloudflare-proxied: "false"`
  - Wildcard CNAMEs go in the separate `keiretsu-top-wildcards` DNSEndpoint in the same file
- Without the CNAME, the HTTPRoute will show Accepted=True but DNS won't resolve and the app will be unreachable

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
# Render-test all clusters (uses flate against clusters/<c>/flux/config)
make test
# Render-test one cluster
make test-talos-ottawa
# Show rendered diff vs origin/main
make diff
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

## Talos Template Structure (`bootstrap/talos/`)

Each Talos cluster uses **talhelper** (`talconfig.yaml`) + per-node patches to generate machine configs. Managed via `mise run <task>` (Taskfile.yaml).

### Directory Layout
```
bootstrap/talos/
├── talconfig.yaml            # Central cluster config (nodes, patches, schematics)
├── talsecret.sops.yaml       # Encrypted secrets (SOPS)
├── Taskfile.yaml             # Task runner (init, genconfig, apply, upgrade, etc.)
├── metal-amd64.iso           # Boot ISO (or metal-arm64.iso for arm64)
├── patches/
│   ├── global/               # Applied to ALL nodes
│   │   ├── cluster-discovery.yaml
│   │   ├── containerd.yaml
│   │   ├── disable-search-domain.yaml
│   │   ├── hostdns.yaml
│   │   ├── kubelet.yaml
│   │   ├── local-path-provisioner.yaml
│   │   ├── machine-logging.yaml   # IP differs per cluster (10.x.69.51:5170)
│   │   ├── metrics-server.yaml
│   │   └── sysctls.yaml
│   ├── controller/           # Applied to control plane nodes only
│   │   ├── api-access.yaml
│   │   ├── disable-proxy.yaml
│   │   ├── etcd-metrics-patch.yaml
│   │   └── kubelet-certs.yaml
│   └── node/                 # Per-node overrides (cluster-specific)
│       ├── shiro-intel.yaml  # Ottawa
│       ├── orin-0.yaml       # St. Petersburg
│       ├── spark-0.yaml      # St. Petersburg (NVIDIA + RDMA)
│       └── spark-1.yaml      # St. Petersburg (NVIDIA + RDMA)
└── clusterconfig/            # Generated per-node machine configs (gitignored)
```

### `talconfig.yaml` Structure
```yaml
talosVersion: v1.13.3
kubernetesVersion: v1.36.1
clusterName: "k8s.<domain>"
endpoint: https://k8s.<domain>:6443
clusterPodNets: ["10.x.0.0/16"]
clusterSvcNets: ["10.y.0.0/16"]
cniConfig: { name: none }           # Cilium installed separately

nodes:
  - hostname: "<name>"
    ipAddress: "<ip>"
    installDiskSelector: { serial: "<disk-serial>" }
    controlPlane: true|false
    networkInterfaces: [...]         # Bond/VIP/dhcp/static per node

patches:                             # Global — applies to all nodes
  - "@./patches/global/<name>.yaml"

controlPlane:
  schematic:
    customization:
      systemExtensions:
        officialExtensions:
          - siderolabs/<extension>   # e.g. gvisor, binfmt-misc, amd-ucode, nvidia-*
      extraKernelArgs: [...]
  patches:
    - "@./patches/controller/<name>.yaml"

worker:
  schematic: { ... }                 # Same structure for worker-only extensions
  patches: []
```

### Key Architecture Decisions
- **CNI:** `none` — Cilium replaces Flannel, kube-proxy disabled
- **VIP:** Single VIP per cluster for API server HA (192.168.X.25)
- **Logging:** Kernel logs via UDP to `10.<location>.69.51:5170`
- **Networking:** `net.ifnames=0`, `mitigations=off`, `apparmor=0` kernel args
- **Performance:** `cpufreq.default_governor=performance`, hugepages, eBPF JIT
- **Cross-cluster differences:**
  - Robbinsdale: 3 CP nodes (no workers)
  - Ottawa: Bonded X710 SFP+ NICs, AMD P-State, NUT client, i915/Intel GPU
  - St. Petersburg: arm64 (Jetson Orin + DGX Spark GB10), NVIDIA GPU extensions, RDMA

### Adding a System Extension
Add `- siderolabs/<extension>` to the `officialExtensions` list in:
1. `controlPlane.schematic` — for control plane nodes
2. `worker.schematic` — for worker nodes (if any)
3. Per-node `.schematic` — for node-specific extensions (e.g. shiro in Ottawa)

Then upgrade nodes via `talosctl upgrade` — each node pulls a new image from the Talos factory with the updated extensions baked in.

---

## Recent Changes (from git history)

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

> **Note:** tsdb has been removed from the live tree (no longer deployed). The
> Tailscale ACL/capability knowledge below is retained as reference; if
> redeployed, it belongs under `kubernetes/apps/base/media/media-ottawa/tsdb/`
> with an Ottawa pointer.

### Deployment (historical)
- **Ottawa:** was `clusters/talos-ottawa/apps/media/app/tsdb/` (in media namespace)
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
