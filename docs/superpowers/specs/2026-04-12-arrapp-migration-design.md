# ArrApp → Primitives Migration Design

**Date:** 2026-04-12  
**Scope:** 44 ArrApp instances across `talos-robbinsdale` and `talos-ottawa`  
**Goal:** Replace the monolithic `ArrApp` KRO composite with raw manifests + prod KRO primitives (StorageStack, raw HTTPRoute)

---

## Background

`ArrApp` is a legacy KRO RGD (`media.keiretsu.ts.net/v1alpha1`) that bundles 7 resources into one:
- Deployment (with or without downloads volume)
- Service (ClusterIP)
- HTTPRoute (private+ts or private+ts+public)
- GarageKey
- PVC
- ReplicationSource
- ReplicationDestination

The prod primitives now cover the storage and routing concerns cleanly. This migration decomposes ArrApp instances into three separate files per app, keeping everything Flux-managed in cluster-specific directories.

---

## File Structure

Each app directory changes from:

```
clusters/talos-{cluster}/apps/media/app/{name}/
├── kustomization.yaml
└── arrapp.yaml
```

to:

```
clusters/talos-{cluster}/apps/media/app/{name}/
├── kustomization.yaml    (updated: remove arrapp.yaml, add 3 new files)
├── app.yaml              (Deployment + Service)
├── httproute.yaml        (raw HTTPRoute)
└── storagestack.yaml     (StorageStack KRO primitive)
```

---

## Field Mapping

### `app.yaml` (Deployment + Service)

| ArrApp field | Usage |
|---|---|
| `name` | Deployment/Service name, container name, label selector |
| `image` + `tag` | Container image (`image:tag`) |
| `port` | containerPort, Service port |
| `puid`, `pgid` | `PUID`, `GUID` env vars |
| `timezone` | `TZ` env var |
| `fsGroup` | `spec.securityContext.fsGroup` |
| `configMountPath` | Volume mount path for config PVC |
| `mediaMountPath` | Volume mount path for media PVC |
| `mediaClaimName` | PVC claim name for media volume |
| `downloadsClaimName` | PVC claim name for downloads (omitted if empty) |
| `downloadsMountPath` | Mount path for downloads (omitted if empty) |

Config PVC claim name is always `${name}-config` (matches ArrApp convention).

### `httproute.yaml` (raw HTTPRoute)

| ArrApp field | Usage |
|---|---|
| `hostname` | Hostname prefix: `${hostname}.${CLUSTER_DOMAIN}` (Flux-substituted) |
| `publicGateway` | If true, adds `public` gateway to parentRefs |
| `homerName` | `item.homer.rajsingh.info/name` annotation |
| `homerSubtitle` | `item.homer.rajsingh.info/subtitle` annotation |
| `homerLogo` | `item.homer.rajsingh.info/logo` annotation |

Homer `keywords` and `service` annotations are hardcoded to ArrApp defaults (`tv, series, automation` / `fas fa-tv`).

Parent gateways: `private` + `ts` (always), `public` (if `publicGateway: true`). All in namespace `home`.

### `storagestack.yaml` (StorageStack)

| ArrApp field | StorageStack field | Notes |
|---|---|---|
| `name` | `spec.name` | Set to `${name}-config` to match existing PVC name |
| `configStorageSize` | `spec.size` | |
| `configStorageClass` | `spec.storageClass` | |
| `volsyncCopyMethod` | `spec.copyMethod` | Ottawa=Snapshot, Robbinsdale=Direct |
| — | `spec.s3Path` | Set to `media/${name}-config` |
| — | `spec.schedule` | Hardcoded `"0 4 * * *"` (matches ArrApp ReplicationSource) |
| — | `spec.restoreMode` | Always `backup-only` |
| — | `metadata.labels[keiretsu.ts.net/location]` | Inferred from path (`talos-ottawa`→`ottawa`, `talos-robbinsdale`→`robbinsdale`) |

**Dropped fields:** `s3Endpoint`, `s3Location`, `resticPassword` (StorageStack defaults handle these), `volsyncSnapshotClass` (ArrApp default `csi-rbdplugin-snapclass` matches StorageStack default — no instance overrides it), `volsyncManualTrigger`, `volsyncPaused`, `volsyncUnlock`, `restoring`, `restorePrevious` (restore is manual going forward via StorageStack `restorePaused`).

---

## PVC Safety

ArrApp PVCs are KRO-owned (ownerReference set on each PVC). Deleting an ArrApp instance causes KRO to cascade-delete the PVC and its data.

**Resolution:** Remove the ownerReference from each PVC before deleting the ArrApp instance. With no ownerReference, KRO cannot cascade-delete the PVC. StorageStack then adopts it via server-side apply.

---

## Migration Script

**Location:** `scripts/arrapp-migration/migrate.py`

The script:
1. Walks all `clusters/talos-*/apps/media/app/*/arrapp.yaml`
2. Parses each ArrApp spec
3. Emits `app.yaml`, `httproute.yaml`, `storagestack.yaml`, updated `kustomization.yaml` in-place
4. Emits `scripts/arrapp-migration/patch-pvcs.sh` — `kubectl patch` commands to remove ownerReferences from all config PVCs on both clusters

The script is idempotent. It does not delete `arrapp.yaml`; that is done via `git rm` after review.

---

## Migration Steps

### Step 1 — Protect PVCs (before any git changes)

```bash
bash scripts/arrapp-migration/patch-pvcs.sh
```

Verify with:
```bash
for ctx in robbinsdale-k8s-operator.keiretsu.ts.net ottawa-k8s-operator.keiretsu.ts.net; do
  echo "=== $ctx ==="
  kubectl get pvc -n media --context $ctx \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.ownerReferences}{"\n"}{end}' \
    | grep -config
done
```

All `-config` PVCs should show empty ownerReferences.

### Step 2 — Generate and commit yaml changes

```bash
python3 scripts/arrapp-migration/migrate.py
git rm clusters/talos-*/apps/media/app/*/arrapp.yaml
git add clusters/talos-*/apps/media/app/
git commit -m "refactor: migrate ArrApp instances to StorageStack + raw manifests"
git push
```

Flux reconciles: ArrApp instances are deleted (KRO attempts cascade-delete but ownerRefs are gone — PVCs survive), new Deployment/HTTPRoute/StorageStack resources are applied.

---

## Restore Workflow (post-migration)

The `restoring` mode from ArrApp (scale to 0 + unpause destination) is replaced by a manual process:

1. Scale Deployment to 0: `kubectl scale deployment <name> -n media --replicas=0`
2. Update StorageStack: set `restoreMode: restore`, `restorePaused: false`, `copyMethod` as needed
3. Wait for VolSync to restore
4. Scale Deployment back to 1
5. Reset StorageStack to `restoreMode: backup-only`

---

## Affected Apps (43 total)

**Ottawa (19):** sonarr-1080p, sonarr-4k, sonarr-anime, radarr-1080p, radarr-4k, radarr-4kremux, radarr-anime, bazarr-1080p, bazarr-4k, bazarr-4kremux, bazarr-anime, lidarr, prowlarr, sabnzbd, autobrr, tautulli, wizarr, overseerr, jellyseerr

**Robbinsdale (24):** sonarr, sonarr-1080p, sonarr-4k, sonarr-anime, radarr, radarr-1080p, radarr-4k, radarr-4kremux, radarr-anime, bazarr, bazarr-1080p, bazarr-4k, bazarr-4kremux, bazarr-anime, lidarr, prowlarr, sabnzbd, autobrr, tautulli, readarr, wizarr, overseerr, jellyseerr, audioarr
