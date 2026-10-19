# csi-driver-smb secretRefs & mountOptions drift (ottawa / robbinsdale)

Findings-only audit of `kubernetes/apps/base/csi-driver-smb/*` and every
static PV / PVC that consumes the driver. No configuration changed.

## Topology

| | Ottawa | Robbinsdale |
|---|---|---|
| HelmRelease | `csi-driver-smb` chart `1.20.3`, ns `csi-driver-smb` (Flux `targetNamespace: kube-system`) | identical + `windows.enabled: false` |
| Secret `csi-smbcreds` | `stringData` from `${SMB_USERNAME}`/`${SMB_PASSWORD}` (ottawa cluster-secrets), **no explicit namespace** | same vars (robbinsdale cluster-secrets), `namespace: kube-system` explicit |
| StorageClass | `nagato-smb` → `//192.168.169.111/media-share` | `unas-smb` → `//192.168.50.115/k8s_shortsnap` |
| SC mountOptions | `dir_mode=0777 file_mode=0777 uid=1001 gid=1001 retrans=3` | `dir_mode=0777 file_mode=0777 uid=1001 gid=1001` |

Both SCCs point provisioner + node-stage secrets at `csi-smbcreds` in
`kube-system`; the Flux Kustomization `targetNamespace: kube-system` places
the namespace-less Ottawa Secret there too, so both resolve. Values are
Flux-substituted from each cluster's SOPS `cluster-secrets` — no plaintext
credentials in git.

## F1 — Static PV `mountOptions` drift vs their StorageClasses (Low)

The 12 static PVs bypass the StorageClass entirely (CSI `volumeAttributes` +
`nodeStageSecretRef` inline), so their per-PV `mountOptions` are the *only*
ones applied. They disagree with each other and with the SCs:

| PV (cluster) | mountOptions beyond `dir_mode/file_mode=0777` |
|---|---|
| `media-share`, `qbittorrent-downloads` (ott) | `retrans=10 actimeo=5` |
| `garage` (ott) | `retrans=10 actimeo=5 vers=3.0` |
| `media-share`, `qbittorrent-downloads` (rb) | `retrans=10 actimeo=5` |
| `garage` (rb) | `vers=3.0` only — no retrans/actimeo |
| `frigate-data-unas`, `frigate-config-unas`, `homeassistant-config-unas`, `prowlarr-config-unas`, `media` rb, `immich-library`, `immich-pics-v2` (rb) | none |

Drift consequences:

- **uid/gid=1001**: present only in the two StorageClasses. Static PVs mount
  with the server-side/default uid-gid; any pod expecting `1001` ownership on
  a static PV depends on the share, not the manifest.
- **retrans**: SC ottawa says `3`, every PV that sets it says `10`. A PV
  migrated to dynamic provisioning would silently change retry behavior.
- **vers=3.0**: pinned on both garage PVs only; everywhere else negotiates.
  Min-version enforcement on the NAS would break the unpinned mounts first.
- **actimeo**: only the media/qb PVs; metadata-cache behavior differs between
  garage (config DB) and media for no documented reason.

None of this is load-bearing today (all PVs are bound, Retain, and
provisioned-by annotated); it is a consistency and future-migration hazard.

## F2 — Secret namespace declaration asymmetry (Info)

Ottawa `secret.yaml` omits `metadata.namespace`; Robbinsdale sets
`namespace: kube-system`. Both land in `kube-system` (Flux
`targetNamespace`), but the omission makes the Ottawa copy correct only
vacuously — any reuse of the manifest outside this pointer (or a future
`targetNamespace` change) re-resolves it silently. Cosmetic; align when next
touching the file.

## F3 — secretRef consumption is coherent (no-finding)

All 12 static PVs use `nodeStageSecretRef: csi-smbcreds/kube-system`, matching
both SC `node-stage-secret-*` parameters; no PV references a missing secret or
wrong namespace. `provisioner-secret` is set on both SCs but no PV carries
`controllerPublishSecretRef`/`nodeExpandSecretRef` — consistent with the
driver's optional semantics. Nothing to fix.

## F4 — robbinsdale-only HelmRelease delta (Info, deliberate?)

rb sets `values.windows.enabled: false`; ottawa does not. Ottawa runs no
Windows nodes either, so the Windows daemonset likely schedules there
harmlessly or the chart default already skips. Not security-relevant; noted
for the next chart-touch.

## Verdict

Findings only; no PR warranted. F1 is the candidate for a follow-up normalise
(mountOptions parity) if the media/storage lane wants one — it touches live
PV specs, so it stays out of this docs change.
