# garage-operator v0.8.0 adoption

Branch: `work/garage-operator-v0.8.0`  
Date: 2026-10-03

Supersedes Renovate PR #3389 (chart `0.7.12` -> `0.8.0` only).

## Adopted

| Change | Where | Notes |
| --- | --- | --- |
| Operator chart `0.7.12` -> `0.8.0` | `kubernetes/apps/base/garage-operator-system/garage-operator-system-install/helmrelease.yaml` | CRDs are templated in the chart (`templates/crds.yaml`) and the HelmRelease uses `crds: CreateReplace`, so they upgrade with the Helm release. All three clusters share this file. |
| Garage `v2.4.0` -> `v2.4.1` (digest-pinned multi-arch index) | `kubernetes/apps/base/garage/garage/garagecluster.yaml` (`GARAGE_IMAGE` default) | v0.8.0 operator default and test target. Patch release: rolling restart, no migration. |
| Stale version string `v2.3.0` -> `v2.4.1` | `docs/reference/architecture.md` | Doc only. |

Rendered diff (`make diff`) is exactly: HelmRelease chart version, operator Deployment image,
`ClusterRole` gains `networking.k8s.io/ingresses` verbs (new optional Ingress support), and
`GarageCluster.spec.image`. CRDs are not part of the render; they ship with the chart.

All 3 clusters' rendered `GarageCluster`/`GarageBucket`/`GarageKey`/`GarageNode`/`GarageReferenceGrant`
objects validate against the v0.8.0 JSON schemas (only `spec.s3Api.region` is reported "missing" by
kubeconform because it has a CRD default; same as before).

## Deliberately NOT adopted

- `websiteExposure` (operator-managed HTTPRoute/Ingress): cannot express the `Cache-Control`
  `ResponseHeaderModifier`, the apex host rewrite, or the two-Gateway layout of `httproute-web.yaml`
  and `components/cdn-site`, and would rename the route (`<bucket>-website`), breaking the k8gb
  `Gslb` that references the route by name. It also needs `gatewayAPI.enabled=true` in chart values
  (default `false` in 0.8.0). Revisit for a simple website bucket.
- `volumeAttributesClassName`: storage is SMB, local-path and Ceph RBD (ceph-csi); no confirmed
  VolumeAttributesClass/ModifyVolume support. Not worth risk on stateful volumes.
- Pod extras fields: nothing to replace.
- `siteRole` (Writer/Follower): absent == Writer == current behavior. The 3 sites each use a Manual
  layout with their own nodes; changing roles changes layout-write behavior and needs its own plan.
- Native Kubernetes discovery (`spec.discovery.*`): not used; peering is over ClusterMesh/MCS. This is
  also why the v2.4.0 discovery crypto-provider bug (fixed in v2.4.1) did not affect us.
- Dropping `raj-assistant-web` `spec.bucketId`: kept; status is lost on re-create, so the explicit ID
  is more robust for GitOps rebuilds.
- `importKey` grammar relaxation: no change needed (`border0-terraform-key` uses `importKey.secretRef`).
- `homepage/garage.html` version badge (still says v2.3.0): left alone on purpose, changing it rolls
  the homepage Deployment (configmap hash) for no functional reason.

## Risks

1. Operator and Garage bumps land together on three federated sites. Mitigated by the Garage bump
   being a separate commit and Flux reconciling sites independently; Garage rolls one pod at a time
   and `replicationFactor: 3` / `consistencyMode: degraded` tolerate one pod down.
2. CRD changes are additive but applied through Helm; if the Helm upgrade stalls, apply CRDs manually.
3. New admission guard rails (bucketId claim uniqueness, importKey grammar) could reject existing
   objects on update. Existing ~40 buckets/keys render and validate; watch for `ImportKeyRejected`.
4. Refresh requeue (#444) means roughly one extra Admin API read per object every ~5 minutes.
5. Live clusters were not inspected when preparing this change.

## Rollout

1. Merge. Flux upgrades the `garage-operator` HelmRelease per cluster (CRDs included).
2. Per cluster: `kubectl -n garage-operator-system rollout status deploy/garage-operator`; confirm
   webhook endpoints are healthy and the HelmRelease is Ready.
3. Garage pods roll one by one to v2.4.1. Check `GarageCluster` Ready, layout version unchanged
   (`kubectl get garagecluster -n garage`), no `DiscoveryCompatible` condition, and an S3 PUT/HEAD
   against a Zot or Velero bucket.
4. Check GarageBucket/GarageKey `Ready` and no new `ImportKeyRejected` reasons.

## Rollback

- Garage only: revert the `garagecluster.yaml` commit (v2.4.1 -> v2.4.0 is a safe patch rollback).
- Operator: revert the HelmRelease commit (chart 0.7.12). CRD additions remain in the CRD and are
  harmless to the older operator.
- Cluster-side steps: none manual in the normal path. Fallback if the Helm CRD upgrade stalls:
  `kubectl apply --server-side -f` the CRDs from the chart (`helm template ... --include-crds`).
