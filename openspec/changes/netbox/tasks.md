# Netbox Implementation Tasks

> **Assignee**: Leon (implementation agent)  
> **Spec References**: [proposal.md](./proposal.md) | [requirements.md](./specs/requirements.md) | [design.md](./design.md) | [scenarios.md](./specs/scenarios.md)

## Prerequisites

Before starting implementation, ensure:
- [ ] Access to `keiretsu-labs/kubernetes-manifests` repo
- [ ] SOPS encryption keys available for the Ottawa cluster
- [ ] Unifi controller credentials (username, password, MFA seed) obtained from Raj
- [ ] NetBox superuser password decided
- [ ] Verify Robbinsdale UDM (`192.168.50.1`) is reachable from Ottawa cluster pods

## Task 1: Add Helm Repository

**File**: `clusters/common/flux/repositories/helm/netbox.yaml`

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

- [ ] Create the HelmRepository manifest
- [ ] Add to `clusters/common/flux/repositories/helm/kustomization.yaml`

## Task 2: Create App Directory Structure

Create the following directory tree:

```
clusters/talos-ottawa/apps/netbox/
├── namespace.yaml
├── kustomization.yaml
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    ├── httproute.yaml
    ├── pg.yaml
    ├── redis.yaml
    ├── secret.sops.yaml
    └── unifi-sync/
        ├── cronjob.yaml
        └── configmap.yaml
```

- [ ] Create `namespace.yaml` — namespace `netbox` with prune disabled label
- [ ] Create top-level `kustomization.yaml` — includes namespace.yaml + ks.yaml
- [ ] Create `ks.yaml` — Flux Kustomization with dependsOn cnpg-system and dragonfly-operator-system

## Task 3: PostgreSQL (CNPG Cluster)

**File**: `clusters/talos-ottawa/apps/netbox/app/pg.yaml`

- [ ] Create CNPG `Cluster` resource named `netbox-postgres`
  - 3 instances
  - `ceph-block-replicated-nvme` storage class
  - 10Gi storage
  - Bootstrap with database `netbox`, owner `netbox`
  - Enable pod monitoring
  - Configure Barman Cloud S3 backup plugin (reference Immich pg.yaml pattern)
- [ ] Create `ScheduledBackup` resource for daily backups
- [ ] Create Barman `ObjectStore` resource for S3 backup destination (if needed; check if shared)
- [ ] Verify CNPG auto-creates `netbox-postgres-app` secret

## Task 4: Dragonfly (Redis)

**File**: `clusters/talos-ottawa/apps/netbox/app/redis.yaml`

- [ ] Create Dragonfly resource named `dragonfly-netbox`
  - 2 replicas
  - 512MB max memory
  - `--cluster_mode=emulated` for multi-database support
  - Authentication via `netbox-dragonfly-secret`
- [ ] Generate and encrypt Dragonfly password in secret.sops.yaml

## Task 5: Secrets

**File**: `clusters/talos-ottawa/apps/netbox/app/secret.sops.yaml`

Create SOPS-encrypted secret containing:

- [ ] `netbox-dragonfly-secret` — Dragonfly password
- [ ] `netbox-superuser` — NetBox admin username, password, email, API token
- [ ] `netbox-secret` — Django secret_key (generate with `openssl rand -hex 50`)
- [ ] `netbox-unifi-sync` — Unifi credentials (username, password, MFA secret, NetBox API token)

> **Note**: May need multiple secret resources or a single multi-key secret. Follow whichever pattern the Helm chart expects. Check chart docs for exact secret key names.

## Task 6: HelmRelease

**File**: `clusters/talos-ottawa/apps/netbox/app/helmrelease.yaml`

- [ ] Create HelmRelease for netbox chart
- [ ] Disable bundled PostgreSQL (`postgresql.enabled: false`)
- [ ] Configure external database pointing to `netbox-postgres-rw` with CNPG secret
- [ ] Disable bundled Redis (`redis.enabled: false`)
- [ ] Configure cachingRedis pointing to `dragonfly-netbox` (database 0)
- [ ] Configure tasksRedis pointing to `dragonfly-netbox` (database 1)
- [ ] Set superuser from existing secret
- [ ] Set secretKey from existing secret
- [ ] Enable GraphQL
- [ ] Set `enforceGlobalUnique: true`
- [ ] Configure media persistence (5Gi, ceph-block-replicated-nvme)
- [ ] Enable worker deployment
- [ ] Set resource requests/limits per design.md
- [ ] Disable ingress (we use HTTPRoute)
- [ ] Pin chart version (check latest stable on ArtifactHub)

## Task 7: HTTPRoute

**File**: `clusters/talos-ottawa/apps/netbox/app/httproute.yaml`

- [ ] Create HTTPRoute for `netbox.${CLUSTER_DOMAIN}`
- [ ] Reference appropriate gateway (private or Tailscale)
- [ ] Backend ref to netbox service on port 80
- [ ] Add external-dns annotation if needed

## Task 8: Unifi Sync — ConfigMap

**File**: `clusters/talos-ottawa/apps/netbox/app/unifi-sync/configmap.yaml`

- [ ] Create ConfigMap `unifi2netbox-config` with config.yaml contents
- [ ] Configure both Unifi controller URLs (Ottawa: `https://192.168.169.1`, Robbinsdale: `https://192.168.50.1`)
- [ ] Configure site mappings (Unifi site names → NetBox site names)
- [ ] Set NetBox internal URL (`http://netbox.netbox.svc.cluster.local:80`)
- [ ] Set device roles and tenant

## Task 9: Unifi Sync — CronJob

**File**: `clusters/talos-ottawa/apps/netbox/app/unifi-sync/cronjob.yaml`

- [ ] Create CronJob `unifi2netbox-sync`
- [ ] Schedule: `0 */6 * * *` (every 6 hours)
- [ ] Init container: clone unifi2netbox repo
- [ ] Main container: install deps and run sync
- [ ] Mount config from ConfigMap
- [ ] Mount credentials from `netbox-unifi-sync` secret
- [ ] Set concurrencyPolicy: Forbid
- [ ] Set backoffLimit: 2
- [ ] Keep 3 successful and 3 failed job histories

> **Implementation note**: Consider building a custom Docker image instead of cloning at runtime. If creating a Dockerfile, add it to the repo and set up a GitHub Actions workflow to build/push.

## Task 10: App Kustomization

**File**: `clusters/talos-ottawa/apps/netbox/app/kustomization.yaml`

- [ ] List all resources: helmrelease, httproute, pg, redis, secret.sops, unifi-sync/

## Task 11: Flux Integration

- [ ] Ensure the netbox app is picked up by Flux's recursive discovery
- [ ] Verify the app path matches the Kustomization spec in ks.yaml
- [ ] Check that CLUSTER_NAME substitution works in the ks.yaml path

---

## Testing Steps

### Test 1: Database Connectivity
- [ ] Verify CNPG cluster becomes healthy (3/3 pods running)
- [ ] Verify `netbox-postgres-app` secret is auto-created
- [ ] Test connection from a debug pod: `psql -h netbox-postgres-rw -U netbox -d netbox`

### Test 2: Dragonfly Connectivity
- [ ] Verify Dragonfly pods are running (2/2)
- [ ] Test Redis CLI connection: `redis-cli -h dragonfly-netbox -a <password> ping`

### Test 3: NetBox Deployment
- [ ] Verify NetBox pod starts without errors
- [ ] Check logs for successful database migration
- [ ] Verify worker pod starts
- [ ] Check superuser was created: `kubectl exec -it <netbox-pod> -- python /opt/netbox/netbox/manage.py createsuperuser --noinput` (should say user exists)

### Test 4: Web Access
- [ ] Access NetBox UI at `https://netbox.${CLUSTER_DOMAIN}`
- [ ] Login with superuser credentials
- [ ] Verify API is accessible at `https://netbox.${CLUSTER_DOMAIN}/api/`
- [ ] Verify GraphQL at `https://netbox.${CLUSTER_DOMAIN}/graphql/`

### Test 5: Unifi Sync
- [ ] Manually trigger CronJob: `kubectl create job --from=cronjob/unifi2netbox-sync manual-sync -n netbox`
- [ ] Check job logs for successful sync
- [ ] Verify Ottawa devices appear in NetBox UI under Devices
- [ ] Verify Robbinsdale devices appear in NetBox UI under Devices
- [ ] Verify device types are correct (Ubiquiti manufacturer)
- [ ] Verify IP addresses are assigned to devices

### Test 6: Backup
- [ ] Verify ScheduledBackup resource exists
- [ ] Trigger manual backup: check Barman Cloud backup completes
- [ ] Verify backup appears in Ceph S3 bucket

---

## Acceptance Criteria

| # | Criteria | Verified |
|---|----------|----------|
| AC-1 | NetBox pods are running and healthy in the netbox namespace | ☐ |
| AC-2 | CNPG PostgreSQL cluster is running with 3 replicas | ☐ |
| AC-3 | Dragonfly is running with 2 replicas | ☐ |
| AC-4 | Web UI is accessible at `netbox.killinit.cc` via private/Tailscale gateway | ☐ |
| AC-5 | Superuser can log in and access all features | ☐ |
| AC-6 | REST API responds at `/api/` with valid data | ☐ |
| AC-7 | Ottawa Unifi devices are synced and visible in NetBox | ☐ |
| AC-8 | Robbinsdale Unifi devices are synced and visible in NetBox | ☐ |
| AC-9 | Devices have correct site assignment (Ottawa / Robbinsdale) | ☐ |
| AC-10 | IP addresses from Unifi controllers are recorded in NetBox IPAM | ☐ |
| AC-11 | PostgreSQL backups are configured and running | ☐ |
| AC-12 | All secrets are SOPS-encrypted (no plaintext credentials in repo) | ☐ |
| AC-13 | All manifests follow existing repo patterns (FluxCD, CNPG, Dragonfly) | ☐ |
| AC-14 | CronJob runs on schedule and syncs without errors | ☐ |

---

## Post-Implementation (Future Enhancements)

These are explicitly **out of scope** for the initial implementation but documented for future planning:

- [ ] Add Gatus health check endpoint for NetBox
- [ ] Import detailed Ubiquiti device type templates (port maps, power draws)
- [ ] Seed initial prefixes and VLANs from cluster-settings ConfigMaps
- [ ] SSO/OIDC integration (Pocket ID / Authentik)
- [ ] NetBox custom scripts for automated IP allocation
- [ ] St. Petersburg cluster Unifi integration
- [ ] Grafana dashboard for NetBox metrics
- [ ] NetBox plugins (e.g., netbox-topology-views, netbox-bgp)
