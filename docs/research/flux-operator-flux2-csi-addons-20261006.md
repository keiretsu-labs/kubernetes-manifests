# Flux Operator, Flux2, and CSI-Addons findings

Research date: 2026-10-06. This note uses upstream project documentation/source
and the repository's current manifests/PRs. No manifests or Renovate
configuration were changed.

## Summary

- Flux Operator, the `FluxInstance` custom resource, the `flux-instance` Helm
  chart, and upstream Flux2 are different layers. The operator chart installs
  the controller; the `flux-instance` chart is a thin wrapper that creates a
  `FluxInstance`; the CR selects/configures the Flux distribution; and Flux2 is
  the distribution containing the source, kustomize, Helm, notification, image,
  and watcher controllers.
- In an operator-managed installation, upgrading the operator can upgrade the
  Flux controllers. The operator's documented contract is automatic upgrades
  within the `FluxInstance.spec.distribution.version` semver range. This repo
  uses `2.x`, so it is intentionally not pinned to one Flux2 patch release.
  An exact version, a disabled/missing `FluxInstance`, or an unavailable
  candidate would prevent that automatic movement.
- CSI-Addons is an extension API/controller plus a sidecar protocol; it is not
  Rook, Ceph, or the primary Ceph-CSI driver. Rook/Ceph-CSI supplies the storage
  driver pods and Rook can inject the CSI-Addons sidecar into them. The separate
  CSI-Addons deployment supplies the CRDs and controller that send extended
  operations to those sidecars. That separation in this repo is intentional.
- The current CSI-Addons update needs compatibility review: PR #3125 changes
  the controller/CRD source from v0.15.0 to v0.15.1, while the Rook v1.20.2 and
  v1.20.4 chart defaults use a v0.14.0 CSI-Addons sidecar unless this repo
  overrides the sidecar tag. The local comment already says the controller and
  sidecar tags must move together.

## 1. Flux Operator, FluxInstance, and Flux2

### The layers

| Layer | What it is | Evidence in this repo/upstream |
|---|---|---|
| Flux Operator | A Kubernetes CRD controller that manages the lifecycle and reconciliation of Flux installations. | Upstream describes it as a “Kubernetes CRD controller” that automates installation, configuration, and upgrades of Flux controllers ([operator README](https://github.com/controlplaneio-fluxcd/flux-operator/blob/v0.61.0/README.md)). |
| `FluxInstance` | The operator's declarative API. Its `spec.distribution` selects the Flux version/range, registry, artifact, components, and customization. | The upstream API requires `spec.distribution.version` as either an exact version or semver range ([FluxInstance API](https://github.com/controlplaneio-fluxcd/flux-operator/blob/v0.61.0/docs/api/v1/fluxinstance.md)). |
| `flux-instance` chart | A thin Helm wrapper around the `FluxInstance` CR; it is not another controller distribution. | The upstream chart README calls it a “thin wrapper around the `FluxInstance` custom resource” ([chart README](https://github.com/controlplaneio-fluxcd/charts/blob/f5815423bc090cb6fdbbf6935ffb288a1508020b/charts/flux-instance/README.md)). |
| Flux2 | The upstream Flux distribution/manifests and its component controllers. | Flux2's install Kustomization lists source-, kustomize-, notification-, Helm-, image-, and source-watcher bases ([Flux2 v2.9.6 install](https://github.com/fluxcd/flux2/blob/v2.9.6/manifests/install/kustomization.yaml)). |

The two Helm releases in this repo therefore have different jobs:

- `kubernetes/apps/base/flux-system/flux-system-common/flux-operator/app/helmrelease.yaml:2-28` installs the `flux-operator` chart.
- `kubernetes/apps/base/flux-system/flux-system-common/flux-instance/app/helmrelease.yaml:2-26` installs the `flux-instance` wrapper and sets `instance.distribution.version: "2.x"` and `registry: ghcr.io/fluxcd`.
- `kubernetes/apps/ottawa/flux-system/flux-system.yaml:40-78` (and the equivalent Robbinsdale/St. Petersburg pointers) applies the operator Kustomization first and declares the instance Kustomization `dependsOn: flux-operator`.

That is why Renovate can see two chart dependencies in PR #3346 without there
being two independent Flux controller installations. Both charts are released
together by the upstream charts project; the v0.61.0 chart metadata identifies
the operator chart and instance chart as separate application packages with the
same app release ([operator chart README](https://github.com/controlplaneio-fluxcd/charts/blob/f5815423bc090cb6fdbbf6935ffb288a1508020b/charts/flux-operator/README.md),
[instance chart README](https://github.com/controlplaneio-fluxcd/charts/blob/f5815423bc090cb6fdbbf6935ffb288a1508020b/charts/flux-instance/README.md)).

### Does an operator upgrade upgrade Flux controllers?

Yes, conditionally, and this is the intended model.

1. The upstream Flux Operator guide says that `FluxInstance` “install[s] and
   configure[s] the automated update of the Flux distribution.” It explicitly
   says that after a Flux Operator update, a newer Flux patch within the
   configured semver range is applied without changing the `FluxInstance`
   resource ([controller configuration guide](https://github.com/controlplaneio-fluxcd/flux-operator/blob/v0.61.0/docs/guides/instance/instance-controllers.md)).
2. The v0.60.0 operator source contains Flux v2.9.5 manifests under
   `config/data/flux/v2.9.5`; v0.61.0 contains v2.9.6 ([v0.60.0 inventory](https://github.com/controlplaneio-fluxcd/flux-operator/tree/v0.60.0/config/data/flux/v2.9.5),
   [v0.61.0 inventory](https://github.com/controlplaneio-fluxcd/flux-operator/tree/v0.61.0/config/data/flux/v2.9.6)).
3. The reconciler source says it resolves the requested version against
   manifests embedded in the running operator image and then applies the built
   controller resources ([`fluxinstance_controller.go`](https://github.com/controlplaneio-fluxcd/flux-operator/blob/v0.61.0/internal/controller/fluxinstance_controller.go),
   especially the `MatchVersionWithEmbedded` call). If a distribution artifact
   is configured, the operator fetches its current digest and requests another
   reconciliation when that digest changes ([`fluxinstance_artifact_controller.go`](https://github.com/controlplaneio-fluxcd/flux-operator/blob/v0.61.0/internal/controller/fluxinstance_artifact_controller.go)).

The important qualification is that “operator upgrade” is not synonymous with
“every Flux2 release is installed.” The range, artifact, available manifests,
components, and reconciliation state still control the result. The published
`flux-instance` chart defaults its artifact to
`oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:latest`; this repo
overrides the range and registry but leaves the chart's artifact default in
place (`helmrelease.yaml:22-26`). An exact `2.9.5` would be a different policy
from the repo's current `2.x` range.

The raw Flux2 reference in
`clusters/common/bootstrap/flux/kustomization.yaml:1-9` is a separate,
one-time bootstrap input. The file itself says it is not tracked by Flux. PR
#3342 therefore updates initial bootstrap material and the Flux CLI bundled in
the webtop image; it does not replace the operator-managed `FluxInstance`
version policy for already bootstrapped clusters.

## 2. CSI-Addons, Rook, Ceph-CSI, and the repo split

The upstream CSI-Addons project describes the topology directly:

```text
user CR -> CSI-Addons controller -> gRPC -> CSI-Addons sidecar
                                             (inside CSI driver pods)
```

The controller watches CSI-Addons CRs, discovers `CSIAddonsNode` objects, and
forwards operations to sidecars. The sidecar registers its endpoint and
capabilities by creating a `CSIAddonsNode` CR ([CSI-Addons README](https://github.com/csi-addons/kubernetes-csi-addons/blob/v0.15.1/README.md),
[`csiaddonsnode.md`](https://github.com/csi-addons/kubernetes-csi-addons/blob/v0.15.1/docs/csiaddonsnode.md)).
The versioned controller deployment is a separate bundle of CRDs, RBAC, and a
controller-manager Deployment ([controller deployment guide](https://github.com/csi-addons/kubernetes-csi-addons/blob/v0.15.1/docs/deploy-controller.md),
[`deploy/controller/setup-controller.yaml`](https://github.com/csi-addons/kubernetes-csi-addons/blob/v0.15.1/deploy/controller/setup-controller.yaml),
[`deploy/controller/crds.yaml`](https://github.com/csi-addons/kubernetes-csi-addons/blob/v0.15.1/deploy/controller/crds.yaml)).

The layers are:

- **Rook-Ceph:** the Kubernetes operator/Helm layer that creates and manages
  Ceph clusters and configures the storage integration.
- **Ceph-CSI:** the CSI driver that implements Kubernetes volume provisioning,
  attachment, and mounting for Ceph RBD/CephFS ([Ceph-CSI README](https://github.com/ceph/ceph-csi/blob/88dc2009bf531a3f9d8305030efe4654dd30827f/README.md)).
- **CSI-Addons:** an extension API and controller for operations that are not
  part of the core CSI lifecycle. Its sidecar is placed in Ceph-CSI's
  provisioner/node-plugin pods; its controller and CRDs run separately.

For network fencing specifically, the CSI-Addons `NetworkFenceClass` identifies
the storage provisioner and credentials/parameters; the controller asks the
provider for fence clients, and the sidecar/driver performs the storage
operation ([CSI-Addons NetworkFenceClass](https://github.com/csi-addons/kubernetes-csi-addons/blob/v0.15.1/docs/networkfenceclass.md)).
Ceph-CSI implements that operation with Ceph OSD blocklisting and documents
the controller, CRD, sidecar endpoint, and fencing prerequisites
([Ceph-CSI network fencing](https://github.com/ceph/ceph-csi/blob/88dc2009bf531a3f9d8305030efe4654dd30827f/docs/csi-addons/networkfence.md)).
Rook's own documentation makes the split explicit: deploy the CSI-Addons
controller separately, then enable the sidecar in the RBD provisioner and
node-plugin pods ([Rook Ceph-CSI drivers](https://github.com/rook/rook/blob/9f8960d3dd08ff745a365dd83a486c34bf340620/Documentation/Storage-Configuration/Ceph-CSI/ceph-csi-drivers.md#csi-addons-controller),
[Rook CSI configuration](https://github.com/rook/rook/blob/9f8960d3dd08ff745a365dd83a486c34bf340620/Documentation/Storage-Configuration/Ceph-CSI/csi-configuration.md#network-fencing)).

### How this repo implements that split

- `clusters/common/flux/repositories/git/csi-addons.yaml:2-18` points at the
  upstream CSI-Addons repository and keeps only `deploy/controller`.
- `kubernetes/apps/ottawa/csi-addons/csi-addons.yaml:13-22` and the Robbinsdale
  equivalent deploy that controller/CRD bundle and wait for `rook-ceph-operator`.
- `kubernetes/apps/ottawa/csi-addons/csi-addons-config.yaml:11-20` and
  `kubernetes/apps/base/csi-addons/csi-addons-config-ottawa/app/networkfenceclass.yaml:9-18`
  apply this repo's storage-specific configuration after the controller exists.
- The Rook HelmReleases enable the CSI-Addons sidecar in Ceph-CSI pods, while
  their comments explicitly say the controller and CRDs come from the separate
  `csi-addons` app (`kubernetes/apps/base/rook-ceph/rook-ceph-ottawa/app/helmrelease.yaml:27-37`;
  same Robbinsdale path).

So the separation is necessary because the controller/CRD lifecycle belongs to
CSI-Addons, while the sidecar image and Ceph-CSI pod composition belong to the
Rook/Ceph-CSI deployment. They are coupled at runtime, but they are not the
same component or release.

### Version caveat for #3125

The upstream Rook chart values at both versions used here default to:

- Ceph-CSI image `v3.17.0`;
- CSI-Addons sidecar image `quay.io/csiaddons/k8s-sidecar:v0.14.0`.

See the official [Rook v1.20.4 values](https://github.com/rook/rook/blob/v1.20.4/deploy/charts/rook-ceph/values.yaml) and [Rook v1.20.2 values](https://github.com/rook/rook/blob/v1.20.2/deploy/charts/rook-ceph/values.yaml). The local HelmReleases set `csiAddons.enabled: true` but do not override the sidecar tag. The local CSI-Addons source comment says to bump the controller tag and sidecar tag together (`clusters/common/flux/repositories/git/csi-addons.yaml:11-14`).

Therefore #3125 is not merely an isolated harmless CRD update: it moves the
separately deployed controller source to v0.15.1 while the sidecar remains
implicitly Rook-owned at its chart default unless another change supplies a tag.
The v0.15.1 upstream `setup-controller.yaml` also uses
`quay.io/csiaddons/k8s-controller:latest`, so the Git tag primarily versions the
manifests/CRDs rather than pinning a controller image digest.

## 3. Implications for the current PRs

Observed open PR state: 2026-10-06. These are implications only; no PR was
merged, closed, or edited.

| PR | What it changes | Implication |
|---|---|---|
| [#3346](https://github.com/keiretsu-labs/kubernetes-manifests/pull/3346) | `flux-operator` and `flux-instance` charts `0.60.0` → `0.61.0`. | This is the operator-managed live Flux upgrade path. Upstream v0.61.0 contains Flux v2.9.6 manifests, while the repo's `FluxInstance` asks for `2.x`; it is still critical Flux infrastructure, not a webtop-only update. Keep the existing human-review gate. |
| [#3342](https://github.com/keiretsu-labs/kubernetes-manifests/pull/3342) | One-time bootstrap Flux2 `v2.9.5` → `v2.9.6`, plus webtop's bundled Flux CLI `2.9.5` → `2.9.6`. | These are two different consumers in one PR. The webtop CLI part is non-runtime tooling, but the bootstrap file is critical infrastructure and is not reconciled after bootstrap. Do not treat the combined PR as webtop-only. |
| [#3148](https://github.com/keiretsu-labs/kubernetes-manifests/pull/3148) | `cephcsi` image `v3.17.1` → `v3.18.1` in `rbd-device-observer-daemonset.yaml`. | The PR diff says this pod uses the image only for shell/curl/jq and does not start the CSI driver. It is still under the Rook/Ceph storage surface, so it is not a webtop update and should retain storage review. It does not upgrade the actual Ceph-CSI driver managed by Rook. |
| [#3125](https://github.com/keiretsu-labs/kubernetes-manifests/pull/3125) | CSI-Addons GitRepository tag `v0.15.0` → `v0.15.1`. | The separate controller/CRD update is conceptually correct, but it must be checked against the Rook-injected sidecar version. The current chart defaults and the repo's own coupling comment indicate that this is not ready for blind automerge as a standalone patch. It is storage/CSI infrastructure, not webtop. |

The current `.github/renovate.json:67-119` first enables ordinary cluster
automerge and then explicitly disables it for bootstrap, Flux, Rook/Ceph, and
CSI paths. Its webtop rule also explicitly excludes the cluster-coupled Flux
CLI pin (`.github/renovate.json:152-162`). The disabled-automerge status on
these PRs is therefore consistent with the repository policy; this research did
not change that policy.

## Sources and repository paths

Primary upstream sources used above:

- [Flux Operator v0.61.0](https://github.com/controlplaneio-fluxcd/flux-operator/tree/v0.61.0)
- [Flux Operator charts](https://github.com/controlplaneio-fluxcd/charts/tree/f5815423bc090cb6fdbbf6935ffb288a1508020b/charts)
- [Flux2 v2.9.6](https://github.com/fluxcd/flux2/tree/v2.9.6)
- [CSI-Addons v0.15.1](https://github.com/csi-addons/kubernetes-csi-addons/tree/v0.15.1)
- [Ceph-CSI source](https://github.com/ceph/ceph-csi/tree/88dc2009bf531a3f9d8305030efe4654dd30827f)
- [Rook v1.20.4 source](https://github.com/rook/rook/tree/v1.20.4)

Relevant local source paths are cited inline; the four PRs are linked in the
table above.
