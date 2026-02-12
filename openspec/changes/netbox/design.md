# Netbox Technical Design

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                    Ottawa Cluster (talos-ottawa)              │
│                                                              │
│  ┌─────────────┐    ┌──────────────────┐    ┌────────────┐  │
│  │   Envoy     │───▶│   NetBox Pod     │───▶│  CNPG      │  │
│  │   Gateway   │    │  (Helm Release)  │    │  PostgreSQL │  │
│  │  HTTPRoute  │    │                  │───▶│  3 replicas │  │
│  └─────────────┘    │  - Web UI        │    └────────────┘  │
│                     │  - REST API      │                     │
│                     │  - GraphQL       │    ┌────────────┐  │
│                     │  - Worker        │───▶│ Dragonfly   │  │
│                     └──────────────────┘    │ 2 replicas  │  │
│                                             └────────────┘  │
│  ┌──────────────────────────┐                                │
│  │  unifi2netbox CronJob    │                                │
│  │  (every 6 hours)         │──────────┐                     │
│  └──────────────────────────┘          │                     │
│                                        ▼                     │
│                              NetBox API (internal)           │
│                                                              │
└──────────────────────────────────────────────────────────────┘
         │                                       │
         │ Tailscale / LAN                       │ Tailscale / LAN
         ▼                                       ▼
  ┌──────────────┐                      ┌──────────────┐
  │ Ottawa UDM   │                      │ Robbinsdale  │
  │ 192.168.169.1│                      │ UDM          │
  │ Unifi API    │                      │ 192.168.50.1 │
  └──────────────┘                      │ Unifi API    │
                                        └──────────────┘
```

## Deployment Approach

### Namespace

Create `netbox` namespace following the existing pattern:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: netbox
  labels:
    kustomize.toolkit.fluxcd.io/prune: disabled
```

### Directory Structure

```
clusters/talos-ottawa/apps/netbox/
├── namespace.yaml
├── kustomization.yaml          # Top-level: includes namespace.yaml + ks.yaml
├── ks.yaml                     # Flux Kustomization pointing to app/
└── app/
    ├── kustomization.yaml      # App-level: lists all resources
    ├── helmrelease.yaml        # NetBox Helm chart
    ├── httproute.yaml          # Envoy Gateway route
    ├── pg.yaml                 # CNPG PostgreSQL cluster
    ├── redis.yaml              # Dragonfly instance
    ├── secret.sops.yaml        # SOPS-encrypted secrets
    └── unifi-sync/
        ├── cronjob.yaml        # unifi2netbox CronJob
        ├── configmap.yaml      # unifi2netbox config.yaml
        └── kustomization.yaml
```

Additionally, add to the common Flux repository:

```
clusters/common/flux/repositories/helm/netbox.yaml   # HelmRepository
```

### Flux Kustomization (ks.yaml)

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app netbox
  namespace: flux-system
spec:
  targetNamespace: netbox
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: cnpg-system
    - name: dragonfly-operator-system
  path: ./clusters/${CLUSTER_NAME}/apps/netbox/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: kubernetes-manifests
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

## PostgreSQL — CNPG Cluster

Following the established pattern from Immich and Gatus:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: netbox-postgres
  namespace: netbox
spec:
  instances: 3
  bootstrap:
    initdb:
      database: netbox
      owner: netbox
      dataChecksums: true
  monitoring:
    enablePodMonitor: true
  storage:
    size: 10Gi
    storageClass: ceph-block-replicated-nvme
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: netbox-s3-store
        serverName: netbox-postgres
  backup:
    retentionPolicy: "30d"
```

**Key decisions:**
- **3 instances** for HA (matches existing pattern)
- **10Gi storage** — NetBox metadata is lightweight; 10Gi is more than sufficient
- **ceph-block-replicated-nvme** — same storage class as other CNPG clusters
- **Barman Cloud** backups to Ceph RGW S3 (matching Immich pattern)
- CNPG auto-generates credentials in `netbox-postgres-app` secret with `username`, `password`, `host`, `uri` keys

**Connection in Helm values:**
```yaml
externalDatabase:
  host: netbox-postgres-rw          # CNPG read-write service
  port: 5432
  database: netbox
  existingSecretName: netbox-postgres-app
  existingSecretKey: password
  username from secret: netbox-postgres-app → username
```

## Redis — Dragonfly Instance

Following the established pattern from Immich and Fleet:

```yaml
apiVersion: dragonflydb.io/v1alpha1
kind: Dragonfly
metadata:
  name: dragonfly-netbox
  namespace: netbox
spec:
  replicas: 2
  args:
    - --maxmemory=512M
    - --proactor_threads=2
    - --cluster_mode=emulated
  authentication:
    passwordFromSecret:
      name: netbox-dragonfly-secret
      key: password
  resources:
    requests:
      cpu: 25m
      memory: 512Mi
    limits:
      memory: 768Mi
```

**Key decisions:**
- **2 replicas** matching Fleet pattern (NetBox is not cache-heavy)
- **512MB max memory** — sufficient for NetBox caching and task queue
- **Separate databases**: NetBox requires two Redis databases (caching db=0 and tasks/webhooks db=1)
- Dragonfly with `--cluster_mode=emulated` supports multiple databases

**Connection in Helm values:**
```yaml
# Both caching and tasks point to the same Dragonfly instance
# but use different database numbers
cachingRedis:
  host: dragonfly-netbox
  port: 6379
  database: 0
  existingSecretName: netbox-dragonfly-secret
  existingSecretKey: password

tasksRedis:
  host: dragonfly-netbox
  port: 6379
  database: 1
  existingSecretName: netbox-dragonfly-secret
  existingSecretKey: password
```

## Helm Chart Configuration

### HelmRepository

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: netbox
  namespace: flux-system
spec:
  interval: 2h
  url: https://charts.netbox.oss.netboxlabs.com/
```

### HelmRelease — Key Values

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: netbox
spec:
  interval: 30m
  chart:
    spec:
      chart: netbox
      sourceRef:
        kind: HelmRepository
        name: netbox
        namespace: flux-system
  values:
    image:
      pullPolicy: IfNotPresent

    # Superuser (credentials from SOPS secret)
    superuser:
      existingSecret: netbox-superuser

    # Disable bundled PostgreSQL — we use CNPG
    postgresql:
      enabled: false
    externalDatabase:
      host: netbox-postgres-rw
      port: 5432
      database: netbox
      existingSecretName: netbox-postgres-app
      existingSecretKey: password

    # Disable bundled Redis — we use Dragonfly
    redis:
      enabled: false
    cachingRedis:
      host: dragonfly-netbox
      port: 6379
      database: 0
      existingSecretName: netbox-dragonfly-secret
      existingSecretKey: password
    tasksRedis:
      host: dragonfly-netbox
      port: 6379
      database: 1
      existingSecretName: netbox-dragonfly-secret
      existingSecretKey: password

    # NetBox configuration
    allowedHosts:
      - "*"
    enforceGlobalUnique: true
    loginRequired: false   # Allow read-only access without login
    graphQlEnabled: true
    metricsEnabled: true

    # Persistence for media files
    persistence:
      enabled: true
      storageClass: ceph-block-replicated-nvme
      size: 5Gi

    # Secret key (from SOPS secret)
    existingSecret: netbox-secret

    # Resource requests
    resources:
      requests:
        cpu: 100m
        memory: 512Mi
      limits:
        memory: 1Gi

    # Worker for background tasks
    worker:
      enabled: true
      resources:
        requests:
          cpu: 50m
          memory: 256Mi
        limits:
          memory: 512Mi

    # Disable built-in ingress — we use HTTPRoute
    ingress:
      enabled: false
```

## Unifi API Integration

### Approach: unifi2netbox CronJob

Deploy [unifi2netbox](https://github.com/mrzepa/unifi2netbox) as a Kubernetes CronJob that runs on a schedule.

### Authentication

Unifi controllers require:
1. **Username/Password** — Unifi local account (not Ubiquiti cloud account is preferred, but cloud with MFA is supported)
2. **MFA Secret (OTP seed)** — Base32 string for TOTP generation if using cloud auth
3. **NetBox API Token** — For writing device data

All credentials stored in SOPS-encrypted secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: netbox-unifi-sync
  namespace: netbox
type: Opaque
stringData:
  UNIFI_USERNAME: "<unifi-readonly-user>"
  UNIFI_PASSWORD: "<password>"
  UNIFI_MFA_SECRET: "<otp-seed>"
  NETBOX_TOKEN: "<netbox-api-token>"
```

### Configuration

```yaml
# config.yaml mounted via ConfigMap
UNIFI:
  URLS:
    - https://192.168.169.1    # Ottawa UDM
    - https://192.168.50.1     # Robbinsdale UDM
  USE_SITE_MAPPING: false
  SITE_MAPPINGS:
    "Default": "Ottawa"         # Map Unifi "Default" site to NetBox site names
NETBOX:
  URL: http://netbox.netbox.svc.cluster.local:80
  ROLES:
    WIRELESS: "Wireless AP"
    LAN: "Switch"
  TENANT: "Keiretsu Labs"
```

### CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: unifi2netbox-sync
  namespace: netbox
spec:
  schedule: "0 */6 * * *"   # Every 6 hours
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: unifi2netbox
              image: python:3.12-slim
              command:
                - /bin/sh
                - -c
                - |
                  pip install pynetbox requests pyotp PyYAML python-dotenv python-slugify urllib3
                  cd /app && python main.py
              envFrom:
                - secretRef:
                    name: netbox-unifi-sync
              volumeMounts:
                - name: config
                  mountPath: /app/config/config.yaml
                  subPath: config.yaml
                - name: app-code
                  mountPath: /app
          initContainers:
            - name: clone-repo
              image: alpine/git:latest
              command:
                - git
                - clone
                - --depth=1
                - https://github.com/mrzepa/unifi2netbox.git
                - /app
              volumeMounts:
                - name: app-code
                  mountPath: /app
          volumes:
            - name: config
              configMap:
                name: unifi2netbox-config
            - name: app-code
              emptyDir: {}
```

> **Alternative approach**: Build a custom container image with unifi2netbox pre-installed. This is cleaner but requires maintaining a container image. The init-container approach above works without a custom image registry. Leon should evaluate which approach is better during implementation.

### Unifi Controller Access

Both controllers need to be reachable from the Ottawa cluster:
- **Ottawa UDM** (`192.168.169.1`): Direct LAN access ✅
- **Robbinsdale UDM** (`192.168.50.1`): Requires access via Tailscale or Cilium ClusterMesh

Since the clusters have Cilium BGP peering and Tailscale connectivity, the Robbinsdale UDM should be reachable. Verify during implementation with a simple curl test from a pod in the netbox namespace.

### Device Type Templates

Use the [netbox-ubiquiti-unifi-templates](https://github.com/tobiasehlert/netbox-ubiquiti-unifi-templates) library to populate NetBox with accurate Ubiquiti device type definitions. This can be done:

1. **Manually** via the NetBox UI (Import device types)
2. **Via API** using a one-time init job
3. **Via unifi2netbox** which creates basic device types automatically

Recommend option 3 for initial deployment, with option 1 for adding detailed port templates later.

## HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: netbox
  namespace: netbox
  annotations:
    external-dns.alpha.kubernetes.io/target: "netbox.${CLUSTER_DOMAIN}"
spec:
  parentRefs:
    - name: private-gateway    # Or tailscale-gateway, depending on desired access
      namespace: envoy-gateway-system
  hostnames:
    - "netbox.${CLUSTER_DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: netbox
          port: 80
```

## Secrets Summary

| Secret Name | Keys | Source | Purpose |
|-------------|------|--------|---------|
| `netbox-postgres-app` | `username`, `password`, `host`, `uri` | Auto-generated by CNPG | PostgreSQL credentials |
| `netbox-dragonfly-secret` | `password` | SOPS-encrypted | Dragonfly authentication |
| `netbox-superuser` | `username`, `password`, `email`, `api_token` | SOPS-encrypted | NetBox admin account |
| `netbox-secret` | `secret_key` | SOPS-encrypted | Django secret key |
| `netbox-unifi-sync` | `UNIFI_USERNAME`, `UNIFI_PASSWORD`, `UNIFI_MFA_SECRET`, `NETBOX_TOKEN` | SOPS-encrypted | Unifi sync credentials |

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Robbinsdale UDM not reachable from Ottawa cluster | Medium | High | Test connectivity before deploying sync; may need Tailscale egress or direct route |
| unifi2netbox compatibility with current Unifi firmware | Low | Medium | Test with a single controller first; the project is actively maintained |
| Dragonfly compatibility with NetBox Redis requirements | Low | Medium | Dragonfly is Redis-compatible; already used by Immich which has similar Redis patterns |
| NetBox Helm chart version incompatibility | Low | Low | Pin chart version in HelmRelease; test upgrades in staging |
| CNPG PostgreSQL bootstrap failures | Low | Medium | Follow exact pattern from working Immich deployment |
