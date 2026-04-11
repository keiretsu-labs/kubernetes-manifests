# Keiretsu CRD System — Design Spec

## Problem

Setting up cross-cluster connectivity, S3 storage, and volsync backup/restore in the Keiretsu multi-cluster environment requires 30+ lines of boilerplate YAML per service, spread across 4-5 files, with careful ordering dependencies. Adding a new app that needs cross-cluster reach + backup involves:

- Tailscale LoadBalancer services (per-node + global VIPs)
- ExternalName egress services on every other cluster
- GarageBucket + GarageKey
- PVC with correct dataSourceRef ordering
- ReplicationSource + ReplicationDestination
- k8gb GSLB (optional)

This is error-prone (volsync deadlocks if ordering is wrong, PVCs hang if dataSourceRef points at empty ReplicationDestination) and creates drift between clusters.

## Solution

A set of KRO ResourceGroupDefinition (RGD) CRDs that abstract the cross-cluster infrastructure into composable primitives, plus one composite CRD that chains them.

## CRD Inventory

| CRD | API Group | Kind | Deploys Where | Purpose |
|-----|-----------|------|---------------|---------|
| ServiceIngress | `network.keiretsu.ts.net/v1alpha1` | `ServiceIngress` | Source cluster | Expose service to Tailscale (per-node + global VIP) |
| ServiceEgress | `network.keiretsu.ts.net/v1alpha1` | `ServiceEgress` | All clusters (ArgoCD) | ExternalName services to reach Tailscale hostnames from inside a cluster |
| StorageStack | `storage.keiretsu.ts.net/v1alpha1` | `StorageStack` | Source cluster | GarageBucket + GarageKey + PVC + VolSync backup/restore with auto-detect |
| AppRoute | `network.keiretsu.ts.net/v1alpha1` | `AppRoute` | Source cluster | Gateway API route generation (HTTPRoute, TCPRoute, UDPRoute, TLSRoute, GRPCRoute) |
| GSLBEndpoint | `network.keiretsu.ts.net/v1alpha1` | `GSLBEndpoint` | Source cluster | k8gb Gslb wrapper for DNS load balancing |
| KeiretsuApp | `apps.keiretsu.ts.net/v1alpha1` | `KeiretsuApp` | Source cluster | Composite: chains Deployment + Service + ServiceIngress + StorageStack + AppRoute + GSLBEndpoint |

BackupVerify already exists as `storage.keiretsu.ts.net/v1alpha1` and chains naturally with StorageStack (shares the same restic secret).

## Chain Diagram

```
KeiretsuApp (composite, optional — each primitive is standalone)
  |-- Deployment + Service
  |-- ServiceIngress --> status.fqdn, status.globalFQDN
  |                        |
  |                   ServiceEgress (separate CRD, deployed on all clusters via ArgoCD)
  |-- StorageStack --> status.pvcName, status.secretName
  |     |-- GarageKey --> Secret
  |     |-- Probe Job (auto-detect: does backup exist?)
  |     |-- [if backup exists] ReplicationDestination --> PVC (dataSourceRef)
  |     |-- [if no backup]     PVC (empty)
  |     |-- ReplicationSource
  |-- AppRoute (1..N) --> HTTPRoute | TCPRoute | UDPRoute | TLSRoute | GRPCRoute
  |-- GSLBEndpoint (optional, references AppRoute)
  |-- BackupVerify (optional, chains from StorageStack's secret)
```

## Networking Model — Three Tiers of Addressing

Cross-cluster services get three levels of addressability, all as in-cluster DNS:

| Tier | DNS Name | Resolves To | Use Case |
|------|----------|-------------|----------|
| 1 (local) | `<app>.<ns>.svc.cluster.local` | ClusterIP | Pod-to-pod, same cluster. No Tailscale. |
| 2 (global) | `<app>-global.<ns>.svc.cluster.local` | Egress proxy -> global VIP | Any cluster running the app. Resilient. |
| 3 (per-node) | `<location>-<app>.<ns>.svc.cluster.local` | Egress proxy -> per-node VIP | Target specific cluster. For RPC, replication, debugging. |

Pods cannot reach Tailscale IPs (100.x.x.x) directly — verified by testing. The egress proxy services are the routing mechanism, not just aliases.

## CRD Details

### 1. ServiceIngress

Exposes a local Kubernetes service to the Tailscale network via LoadBalancer services with `loadBalancerClass: tailscale`.

```yaml
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: ServiceIngress
metadata:
  name: garage
  namespace: garage
spec:
  # What to expose
  selector:
    app.kubernetes.io/name: garage
  ports:
    - name: s3-api
      port: 3900
    - name: rpc
      port: 3901
    - name: s3-web
      port: 3902
    - name: admin
      port: 3903

  # Per-node VIP (always created)
  hostname: "${LOCATION}-garage"
  tags: "tag:k8s,tag:${LOCATION}"
  proxyGroup: common-ingress

  # Global VIP (optional)
  global:
    enabled: true
    hostname: "garage"
    tags: "tag:k8s"
    ports: [3900, 3902, 3903]       # port subset — no RPC on global
    proxyGroup: common-ingress

  publishNotReadyAddresses: true
status:
  # Always available (derived from spec, deterministic)
  fqdn: "ottawa-garage.keiretsu.ts.net"
  globalFQDN: "garage.keiretsu.ts.net"

  # Only populated when backing endpoints exist
  tailscaleIP: ""
  globalTailscaleIP: ""

  # True when at least per-node LB has external IP
  ready: false
```

**Creates:**
1. LoadBalancer Service — per-node VIP (`${LOCATION}-<app>.keiretsu.ts.net`)
2. LoadBalancer Service — global VIP (`<app>.keiretsu.ts.net`) if `global.enabled`

**Key design decisions:**
- Per-node VIP is always created. Every cross-cluster service needs a location-specific identity.
- Global VIP is opt-in with port subsetting (garage excludes RPC from global, zot includes everything).
- `proxyGroup` defaults to `common-ingress` but is overridable.
- Status FQDNs are deterministic from spec (available immediately). Tailscale IPs are only populated when backing endpoints exist — the LB stays `<pending>` until app pods are ready.
- `readyWhen` gates on LB IP assignment: `${perNodeService.status.?loadBalancer.?ingress.size() > 0}`
- `publishNotReadyAddresses: true` for bootstrap when pods wait for cluster health (essential for federated apps like garage).

**Chaining note:** ServiceEgress references FQDNs (deterministic), not IPs. So ServiceEgress can be created before ServiceIngress is ready — the egress proxy retries until the ingress side comes up.

### 2. ServiceEgress

Creates ExternalName services that let pods inside a cluster reach Tailscale-exposed services from other clusters.

```yaml
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: ServiceEgress
metadata:
  name: garage
  namespace: garage
spec:
  # Per-cluster endpoints (tier 3: target specific cluster)
  endpoints:
    - name: ottawa-garage
      fqdn: ottawa-garage.keiretsu.ts.net
      ports: [3900, 3901, 3902, 3903]
    - name: robbinsdale-garage
      fqdn: robbinsdale-garage.keiretsu.ts.net
      ports: [3900, 3901, 3902, 3903]
    - name: stpetersburg-garage
      fqdn: stpetersburg-garage.keiretsu.ts.net
      ports: [3900, 3901, 3902, 3903]

  # Global endpoint (tier 2: any cluster with the app)
  global:
    name: garage-global
    fqdn: garage.keiretsu.ts.net
    ports: [3900]

  # Proxy routing
  proxyGroup: common-egress
status:
  services:
    - name: ottawa-garage
      clusterDNS: ottawa-garage.garage.svc.cluster.local
    - name: robbinsdale-garage
      clusterDNS: robbinsdale-garage.garage.svc.cluster.local
    - name: stpetersburg-garage
      clusterDNS: stpetersburg-garage.garage.svc.cluster.local
    - name: garage-global
      clusterDNS: garage-global.garage.svc.cluster.local
  ready: true
```

**Creates:** One ExternalName Service per endpoint + one for global, each annotated with:
- `tailscale.com/tailnet-fqdn: <fqdn>`
- `tailscale.com/proxy-group: <proxyGroup>` (if set)

**Deployment model:** Deployed via ArgoCD ApplicationSet with clusters generator — lands on every cluster. On the source cluster, the egress services point at itself (harmless, traffic stays local).

**Key design decisions:**
- `proxyGroup` controls shared vs standalone proxies. Empty string = standalone proxy per service (one tailscale device each). `common-egress` = shared pool. Currently garage per-cluster egress uses standalone (proxy-group commented out in existing YAML).
- Endpoints list is static YAML — you declare which clusters you want to reach. No auto-discovery. Matches GitOps philosophy.
- Status exposes in-cluster DNS names so chained CRDs or consumers know the service addresses.
- ServiceEgress is fire-and-forget — deploy it, it works as soon as the ingress side comes up.

### 3. StorageStack

Creates the full backup/restore lifecycle for a PVC: Garage S3 credentials, PVC provisioning, and VolSync replication with automatic detection of whether prior backups exist.

```yaml
apiVersion: storage.keiretsu.ts.net/v1alpha1
kind: StorageStack
metadata:
  name: jellyfin-config
  namespace: media
spec:
  # PVC
  size: 20Gi
  storageClass: ceph-block-replicated-nvme
  accessMode: ReadWriteOnce

  # Garage bucket
  bucket:
    create: false                    # false = use shared keiretsu bucket (default)
    globalAlias: keiretsu
    # create: true                   # true = create dedicated bucket
    # globalAlias: jellyfin-data
    # quota: 500Gi

  # S3 path within bucket
  s3Endpoint: "${COMMON_S3_ENDPOINT}"
  s3Location: "${LOCATION}"
  s3Path: "media/jellyfin-config"

  # Backup config
  backup:
    schedule: "0 6 * * *"
    copyMethod: Snapshot             # or Direct
    snapshotClass: csi-rbdplugin-snapclass
    retain:
      hourly: 1
      daily: 3
      weekly: 4
      monthly: 2
      yearly: 1
    pruneIntervalDays: 14
    resticPassword: "${COMMON_RESTIC_SECRET}"

  # Restore behavior
  restore:
    mode: auto                       # auto | backup-only | restore
    copyMethod: Snapshot
    paused: true                     # manual trigger by default
status:
  pvcName: "jellyfin-config"
  secretName: "restic-jellyfin-config"
  bucketReady: true
  lastBackup: "2026-04-11T06:00:52Z"
  ready: true
```

**Creates (ordered by dependency chain):**

```
1. GarageKey --> Secret (AWS creds + RESTIC_REPOSITORY + RESTIC_PASSWORD)
      |
2. GarageBucket (only if bucket.create: true)
      |
3. Probe Job
   - Runs: restic snapshots --json --latest 1
   - Writes to ConfigMap: {"hasBackup": "true"} or {"hasBackup": "false"}
   - readyWhen: job completes
      |
4. Branch via includeWhen on probe result:
   |
   |-- [hasBackup=true OR mode=restore]
   |     ReplicationDestination
   |       --> PVC (dataSourceRef -> ReplicationDestination)
   |
   |-- [hasBackup=false OR mode=backup-only]
   |     PVC (empty, no dataSourceRef)
   |
5. ReplicationSource (sourcePVC, runs on schedule)
```

**Key design decisions:**

- `restore.mode: auto` (default) — probe Job checks if restic repo has snapshots. If yes, restore. If no, fresh PVC. No manual toggle needed.
- `restore.mode: backup-only` — force fresh PVC even if backups exist (fresh start).
- `restore.mode: restore` — force restore, fail loudly if no backups exist (disaster recovery).
- Probe Job is lightweight — `restic snapshots --latest 1` finishes in seconds.
- The deadlock problem (PVC waiting on ReplicationDestination waiting on nonexistent repo) is eliminated by the probe + branch pattern.
- Most apps share the `keiretsu` bucket with path-based isolation. Dedicated buckets via `bucket.create: true` for apps like zot with their own quotas.
- Secret naming follows existing convention: `restic-<name>`.
- Status exposes `pvcName` and `secretName` so KeiretsuApp can mount the PVC and reference the secret.

**Restore mode transition:**
- New app deploys → `auto` probes, finds nothing → empty PVC → first backup runs → repo now exists
- App moves to new cluster → `auto` probes, finds backups → restores → continues backing up
- No git commit needed to transition between phases.

### 4. AppRoute

Generates Gateway API route resources (HTTPRoute, TCPRoute, UDPRoute, TLSRoute, GRPCRoute) with simplified inputs and built-in Homer dashboard integration.

```yaml
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: AppRoute
metadata:
  name: zot-public
  namespace: zot
spec:
  # Route type
  kind: HTTPRoute                    # HTTPRoute | TCPRoute | UDPRoute | TLSRoute | GRPCRoute

  # Target service
  backendRef:
    name: zot-public
    port: 5000

  # Gateway binding (short names, resolved to home namespace)
  parentRefs:
    - gateway: public
    - gateway: ts
    - gateway: private

  # Hostnames (HTTPRoute/TLSRoute/GRPCRoute only)
  hostnames:
    - "oci.${CLUSTER_DOMAIN}"
    - "oci.cdn.keiretsu.top"
    - "zot.cdn.keiretsu.top"

  # Path rules (HTTPRoute only, optional — defaults to /)
  rules:
    - path: /
      type: PathPrefix

  # Homer dashboard integration (optional)
  homer:
    name: "Zot Registry"
    subtitle: "OCI Container Registry"
    logo: "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/docker-moby.png"
    keywords: "registry, oci, containers"
    service: "Infrastructure"
    serviceIcon: "fas fa-server"
status:
  ready: true
  hostnames:
    - "oci.killinit.cc"
    - "oci.cdn.keiretsu.top"
```

**Creates:** One Gateway API route resource based on `spec.kind`:
- `HTTPRoute` — with hostnames, path rules, homer annotations
- `TCPRoute` — with backendRef only (no hostnames/paths)
- `UDPRoute` — with backendRef only
- `TLSRoute` — with hostnames, backendRef
- `GRPCRoute` — with hostnames, backendRef

Route type selection uses `includeWhen` conditions on `spec.kind`.

**Key design decisions:**
- `parentRefs` uses short gateway names (`ts`, `private`, `public`) — the RGD resolves these to full references (`namespace: home, group: gateway.networking.k8s.io, kind: Gateway`). Eliminates 4 lines of boilerplate per gateway binding.
- Homer annotations are first-class optional fields. Almost every HTTPRoute in the repo carries homer annotations for dashboard auto-discovery. Including them in the CRD makes them declarative rather than copy-paste.
- **Multiple AppRoutes per app** — zot has `zot-public` (public gateway) and `zot-internal` (ts + private). Each is a separate AppRoute instance. This is deliberate: different gateways often need different hostnames and auth settings.
- For TCPRoute/UDPRoute, hostname and rule fields are ignored (enforced by `includeWhen` on kind).
- Status exposes resolved hostnames so GSLBEndpoint can reference them.

**KeiretsuApp chains AppRoute via forEach:**

```yaml
# In KeiretsuApp spec
routes:
  - name: zot-public
    kind: HTTPRoute
    parentRefs: [public]
    hostnames: ["oci.${CLUSTER_DOMAIN}", "oci.cdn.keiretsu.top"]
    homer:
      name: "Zot Registry"
  - name: zot-internal
    kind: HTTPRoute
    parentRefs: [ts, private]
    hostnames: ["oci.${CLUSTER_DOMAIN}"]
```

The composite creates one AppRoute instance per entry in the `routes` array using KRO's `forEach`.

### 5. GSLBEndpoint

Wrapper around k8gb Gslb resource for DNS-based global load balancing.

```yaml
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: GSLBEndpoint
metadata:
  name: garage-s3-cdn
  namespace: keiretsu-top
spec:
  httpRouteRef:
    name: garage-s3-cdn
    namespace: garage
  strategy: roundRobin
  dnsTtlSeconds: 60
  weights:
    ottawa: 33
    robbinsdale: 33
    stpetersburg: 34
status:
  dnsName: "s3.cdn.keiretsu.top"
  healthy: true
```

**Creates:** k8gb `Gslb` resource.

Simple one-to-one wrapper. Value is consistent interface for KeiretsuApp chaining and standardized status fields.

### 6. KeiretsuApp (Composite)

Chains all primitives into a single resource for the full-stack experience. Each section is optional. The deployment spec will grow over time to support volume mounts, init containers, resource limits, etc. as needed.

```yaml
apiVersion: apps.keiretsu.ts.net/v1alpha1
kind: KeiretsuApp
metadata:
  name: zot-internal
  namespace: zot
spec:
  # App deployment (will grow as needs arise)
  image: ghcr.io/project-zot/zot-linux-amd64:v2.1.3
  port: 5000
  replicas: 1
  env:
    - name: CONFIG_PATH
      value: /etc/zot/config.json

  # Cross-cluster networking (optional)
  ingress:
    hostname: "${LOCATION}-zot"
    tags: "tag:k8s,tag:${LOCATION}"
    ports: [5000]
    global:
      enabled: true
      hostname: "oci"
      ports: [5000]

  # Gateway API routes (optional, 1..N)
  routes:
    - name: zot-public
      kind: HTTPRoute
      parentRefs: [public]
      hostnames: ["oci.${CLUSTER_DOMAIN}", "oci.cdn.keiretsu.top", "zot.cdn.keiretsu.top"]
      homer:
        name: "Zot Registry"
        subtitle: "OCI Container Registry"
        logo: "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/docker-moby.png"
        service: "Infrastructure"
    - name: zot-internal
      kind: HTTPRoute
      parentRefs: [ts, private]
      hostnames: ["oci.${CLUSTER_DOMAIN}"]

  # Storage + backup (optional)
  storage:
    size: 20Gi
    storageClass: ceph-block-replicated-nvme
    s3Endpoint: "${COMMON_S3_ENDPOINT}"
    s3Location: "${LOCATION}"
    s3Path: "zot/config"
    backup:
      schedule: "0 6 * * *"
      resticPassword: "${COMMON_RESTIC_SECRET}"

  # GSLB (optional, references an AppRoute by name)
  gslb:
    enabled: true
    routeRef: zot-public             # which AppRoute to attach GSLB to
    strategy: roundRobin
    weights:
      ottawa: 33
      robbinsdale: 33
      stpetersburg: 34
status:
  ready: true
  serviceIP: "10.2.213.163"
  fqdn: "ottawa-zot.keiretsu.ts.net"
  globalFQDN: "oci.keiretsu.ts.net"
  pvcName: "zot-internal-config"
  lastBackup: "2026-04-11T06:00:52Z"
```

**Creates instances of:**
- Deployment + Service (always)
- ServiceIngress (if `ingress` specified)
- AppRoute x N (one per entry in `routes`, via `forEach`)
- StorageStack (if `storage` specified)
- GSLBEndpoint (if `gslb.enabled`, references the named AppRoute)

**Does NOT create:** ServiceEgress — that's deployed separately on all clusters via ArgoCD ApplicationSet.

**Dependency chain within KeiretsuApp:**
1. StorageStack first (PVC must exist before Deployment mounts it)
2. Deployment + Service (needs PVC from StorageStack)
3. ServiceIngress (needs Service selector to exist)
4. AppRoute x N (needs Service as backendRef)
5. GSLBEndpoint (references an AppRoute by name)

## GitOps Repository Layout & ArgoCD Placement

Best practice (per ArgoCD community consensus): **labels on clusters drive placement; directory structure organizes manifests**. Don't conflate the two.

Sources: [Codefresh: Structuring Argo CD Repositories](https://codefresh.io/blog/how-to-structure-your-argo-cd-repositories-using-application-sets/), [OneUptime: ArgoCD Multi-Cluster Best Practices](https://oneuptime.com/blog/post/2026-02-26-argocd-best-practices-multi-cluster/view)

### App Manifest Directory Structure

One directory per app. All CRD instances for that app live together.

```
clusters/apps/
  garage/
    ingress.yaml          # ServiceIngress
    storage.yaml          # StorageStack
    egress.yaml           # ServiceEgress
    gslb.yaml             # GSLBEndpoint
    kustomization.yaml
  zot/
    app.yaml              # KeiretsuApp
    egress.yaml           # ServiceEgress
    kustomization.yaml
  jellyfin/
    app.yaml              # KeiretsuApp
    egress.yaml           # ServiceEgress
    kustomization.yaml
```

### ArgoCD ApplicationSets

Three ApplicationSets drive placement. Cluster labels (not directory structure) determine where resources land.

| ApplicationSet | Generator | Selects | What it places |
|---|---|---|---|
| `keiretsu-apps` | Matrix: clusters(`tier=app-host`) x git dirs(`clusters/apps/*/`) | Clusters labeled as app hosts | ServiceIngress, StorageStack, KeiretsuApp — filtered by kustomization target |
| `keiretsu-egress` | Clusters: all registered clusters | Every cluster unconditionally | ServiceEgress — must exist everywhere for cross-cluster DNS |
| `keiretsu-gslb` | Clusters(`has-gslb=true`) | Clusters running k8gb | GSLBEndpoint |

Each app directory has a `kustomization.yaml` with named targets or resource filtering so the ApplicationSets can select which subset of resources to deploy:

```yaml
# clusters/apps/garage/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ingress.yaml
  - storage.yaml
  - egress.yaml
  - gslb.yaml
```

The `keiretsu-apps` ApplicationSet deploys all resources except ServiceEgress (filtered by label or separate kustomization overlay). The `keiretsu-egress` ApplicationSet deploys only ServiceEgress resources.

### Cluster Labels

```yaml
# ArgoCD cluster secrets carry placement labels
metadata:
  labels:
    argocd.argoproj.io/secret-type: cluster
    tier: app-host          # this cluster hosts app workloads
    has-gslb: "true"        # this cluster runs k8gb
    location: ottawa        # cluster location
```

Adding a new cluster: register it with ArgoCD + set labels. All matching ApplicationSets automatically deploy.

### Adding a New App

1. Create `clusters/apps/<name>/` directory
2. Add CRD instance YAML files (KeiretsuApp, ServiceEgress, etc.)
3. Add `kustomization.yaml` listing resources
4. Commit — ArgoCD picks it up automatically via existing ApplicationSets

No new ApplicationSets needed per app.

## Deployment Topology

| Resource | Where it lands | Deployed by | Generator |
|----------|---------------|-------------|-----------|
| ServiceIngress | App-hosting clusters | ArgoCD `keiretsu-apps` | Matrix: cluster labels x git dirs |
| ServiceEgress | All clusters | ArgoCD `keiretsu-egress` | Clusters: all |
| StorageStack | App-hosting clusters | ArgoCD `keiretsu-apps` | Matrix: cluster labels x git dirs |
| AppRoute | App-hosting clusters | ArgoCD `keiretsu-apps` | Matrix: cluster labels x git dirs |
| GSLBEndpoint | GSLB clusters | ArgoCD `keiretsu-gslb` | Clusters: `has-gslb=true` |
| KeiretsuApp | App-hosting clusters | ArgoCD `keiretsu-apps` | Matrix: cluster labels x git dirs |
| BackupVerify | App-hosting clusters | ArgoCD `keiretsu-apps` | Matrix: cluster labels x git dirs |

All placement is via ArgoCD. Flux manages only the KRO operator and RGD definitions (in `clusters/common/apps/kro/`).

## RGD File Organization

RGD definitions (the CRD schemas, not instances) remain in Flux-managed common:

```
clusters/common/apps/kro/rgd/
  service-ingress.yaml        # ServiceIngress RGD
  service-egress.yaml         # ServiceEgress RGD
  storage-stack.yaml          # StorageStack RGD
  app-route.yaml              # AppRoute RGD
  gslb-endpoint.yaml          # GSLBEndpoint RGD
  keiretsu-app.yaml           # KeiretsuApp RGD (composite)
  backupverify.yaml           # BackupVerify RGD (already exists)
```

CRD instances (the actual app declarations) go in ArgoCD-managed:

```
clusters/apps/                # ArgoCD ApplicationSets scan this
  <app-name>/
    *.yaml + kustomization.yaml
```

## Migration Path

These CRDs replace the existing experimental RGDs (App, ArrApp, QbApp, GluetunApp, FloatingApp, MeshEgress, VolsyncBackup). The existing RGDs are experiments and can be removed.

For existing manually-deployed services (garage, zot, temporal):
1. Create ServiceIngress + ServiceEgress instances in `clusters/apps/<service>/`
2. Remove the manual service-ts.yaml, egress.yaml files from `clusters/common/apps/<service>/`
3. Verify cross-cluster connectivity is unchanged

## Probe Job Failure Handling

If the probe Job fails (S3 unreachable, credentials wrong, timeout), StorageStack falls back to `backup-only` behavior (empty PVC). This prevents a transient S3 outage from blocking app deployment. The probe Job uses `ttlSecondsAfterFinished: 300` for cleanup.

Probe Job image: `restic/restic:0.18.0` (same version as volsync mover pods).

## Platform ConfigMap

A cluster-wide ConfigMap provides shared defaults and reference data for all RGDs. Deployed via Flux to `kro-system` on every cluster with Flux variable substitution.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: keiretsu-platform-config
  namespace: kro-system
data:
  # Gateway references (used by AppRoute)
  gateway.ts.name: "ts"
  gateway.ts.namespace: "home"
  gateway.private.name: "private"
  gateway.private.namespace: "home"
  gateway.public.name: "public"
  gateway.public.namespace: "home"

  # Storage defaults (used by StorageStack)
  storage.defaultStorageClass: "ceph-block-replicated-nvme"
  storage.defaultSnapshotClass: "csi-rbdplugin-snapclass"
  storage.defaultBucket: "keiretsu"
  storage.s3Endpoint: "${COMMON_S3_ENDPOINT}"
  storage.resticPassword: "${COMMON_RESTIC_SECRET}"

  # Networking defaults (used by ServiceIngress/Egress)
  network.defaultIngressProxyGroup: "common-ingress"
  network.defaultEgressProxyGroup: "common-egress"
  network.defaultLocalTags: "tag:k8s,tag:${LOCATION}"
  network.defaultGlobalTags: "tag:k8s"
  network.location: "${LOCATION}"

  # Cluster topology (used by ServiceEgress)
  clusters: "ottawa,robbinsdale,stpetersburg"
```

**Impact on CRD instances:**

With the ConfigMap, most CRD instances become much shorter because platform defaults are inherited:

```yaml
# Before (without ConfigMap): StorageStack needs all fields
spec:
  storageClass: ceph-block-replicated-nvme
  s3Endpoint: "${COMMON_S3_ENDPOINT}"
  s3Location: "${LOCATION}"
  backup:
    snapshotClass: csi-rbdplugin-snapclass
    resticPassword: "${COMMON_RESTIC_SECRET}"

# After (with ConfigMap): only non-default fields needed
spec:
  s3Path: "media/jellyfin-config"
  backup:
    schedule: "0 6 * * *"
```

The RGDs read the ConfigMap and use its values as defaults. Per-instance overrides take precedence.

**Note:** KRO does not natively support reading ConfigMaps from within RGD templates. The RGDs will need to use Flux variable substitution (`${VAR}`) for values that come from the platform config, or the platform config values will be baked into the RGD definitions themselves via Flux postBuild. This is an implementation detail to resolve during planning.

## App Directory Structure

Each app gets subdirectories that map to ArgoCD ApplicationSet paths. This matches the existing `floating-apps/` + `floating-apps/egress/` pattern.

```
clusters/apps/
  garage/
    app/                          # keiretsu-apps ApplicationSet: path "clusters/apps/*/app"
      ingress.yaml                # ServiceIngress
      storage.yaml                # StorageStack
      route.yaml                  # AppRoute (1..N)
      kustomization.yaml
    egress/                       # keiretsu-egress ApplicationSet: path "clusters/apps/*/egress"
      egress.yaml                 # ServiceEgress
      kustomization.yaml
    gslb/                         # keiretsu-gslb ApplicationSet: path "clusters/apps/*/gslb"
      gslb.yaml                   # GSLBEndpoint
      kustomization.yaml
  zot/
    app/
      app.yaml                    # KeiretsuApp (composite)
      kustomization.yaml
    egress/
      egress.yaml
      kustomization.yaml
```

Three ApplicationSets scan these paths:

| ApplicationSet | Git Path Pattern | Generator | Deploys To |
|---|---|---|---|
| `keiretsu-apps` | `clusters/apps/*/app` | Matrix: clusters(`tier=app-host`) x git dirs | App-hosting clusters |
| `keiretsu-egress` | `clusters/apps/*/egress` | Clusters: all | Every cluster |
| `keiretsu-gslb` | `clusters/apps/*/gslb` | Clusters(`has-gslb=true`) | GSLB clusters |

No ArgoCD resource filtering needed — the directory structure handles the split.

Sources: [ArgoCD Resource Filters for Sync](https://oneuptime.com/blog/post/2026-02-26-argocd-resource-filters-for-sync/view), [ArgoCD Applications with Shared Resources](https://oneuptime.com/blog/post/2026-02-26-argocd-applications-shared-resources/view), [Codefresh: Structuring Argo CD Repositories](https://codefresh.io/blog/how-to-structure-your-argo-cd-repositories-using-application-sets/)

## Open Questions

None — all design questions resolved.
