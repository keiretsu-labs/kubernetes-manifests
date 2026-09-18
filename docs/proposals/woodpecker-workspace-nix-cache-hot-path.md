# Proposal: remove the workspace-image RWO bottleneck safely

Status: draft proposal. This document is the first landing only; it does not
change the live PVC, Woodpecker agent capacity, or release workflow.

## Problem and current contract

The workspace-image release workflow is restricted to Ottawa agents by the
`nix-cache=true` label. Its `prepare-cache` and `promote` steps both mount the
same `woodpecker/workspace-nix-cache` claim at `/nix`, and the workflow is
serialized because that claim is `ReadWriteOnce`:

| Item | Current value |
| --- | --- |
| Claim | `workspace-nix-cache` |
| Access mode | `ReadWriteOnce` |
| Storage class | `ceph-block-replicated` |
| Capacity | `64Gi` |
| Shared object cache | Garage bucket `nix-cache` |
| Ottawa agent selector | `nix-cache=true` |
| Robbinsdale agent selector | none |

The `nix-cache` Garage bucket already has separate writer and reader keys and
is configured as a Nix substituter. It is the right cross-build exchange
point. It must not be mounted as a POSIX Nix store through FUSE: Nix still
needs a local writable store for each build.

The Ottawa claim remains the durable fallback while an alternative is proved.
This proposal does not change its access mode, storage class, size, name, or
reclaim behavior.

## Decision for the next experiment

Start with an opt-in Garage-backed hot path using disposable local build
storage. Keep the workflow on Ottawa (`nix-cache=true`) and leave Robbinsdale
unlabeled. The shared state is the Garage substituter/cache; `/nix` is
per-build state and is not shared between concurrent release pods.

The experiment must use one of these backend-supported layouts:

1. Run the Nix preparation and promotion in one pod with one bounded
   node-local `emptyDir` mounted at `/nix`; or
2. Use a per-workflow ephemeral PVC/volume supplied by the Woodpecker
   Kubernetes backend and mount that same volume into both steps.

A separate `emptyDir` on each step is not valid: Woodpecker steps can run in
different pods, and promotion would not see the store prepared by the prior
step. The canary must prove the volume identity across both steps before it
can be considered a replacement for the claim.

The first canary should be a separate, explicitly selected workflow or feature
flag with a concurrency limit of two. It must not change the existing
`workspace-image-build` lane until the evidence below is complete. The current
RWO lane remains available as the immediate rollback.

## Staged implementation

### Stage 0 — this proposal

- Do not edit `workspace-nix-cache-pvc.yaml`.
- Do not change `WOODPECKER_AGENT_LABELS`, `WOODPECKER_MAX_WORKFLOWS`, or
  either cluster's agent replica count.
- Do not delete or resize the claim, and do not add a second claim to the
  production kustomization yet.
- Keep the existing Garage bucket, writer key, reader key, signing key, and
  Nix public key contract unchanged.

### Stage 1 — opt-in Garage/local canary in `corp/bhaiya`

Implement the canary in the workspace-image repository, not by mutating the
production PVC. The canary should:

1. retain the `nix-cache=true` agent requirement;
2. use disposable local `/nix` storage with an explicit ephemeral-storage
   request/limit and a bounded size appropriate for the current image build;
3. keep the existing Garage substituter and push the resulting closure to
   `nix-cache` with the CI writer key;
4. use a distinct concurrency group so two canaries can exercise independent
   local stores without contending on the RWO claim; and
5. leave the normal tagged release path on the RWO fallback until the canary
   has passed.

Measure cold and warm build time, peak local storage, Garage substitute hits,
closure push success, retry behavior, and the image digest/adoption handoff.
An empty or evicted local store is an expected cache miss, not a data-loss
event; a failed Garage push must remain visible and must not be silently
treated as a warm-cache success.

### Stage 2 — evaluate `rook-cephfs` separately

Ottawa currently exposes a `rook-cephfs` StorageClass backed by the CephFS
CSI provisioner. That is evidence that an RWX candidate exists, not evidence
that this Nix workload is safe on it. If the disposable local canary is not
adequate, create a separately named canary claim using `ReadWriteMany` and
`rook-cephfs`; never edit the bound RWO claim in place.

The RWX canary must exercise two independent build pods concurrently and
verify Nix locking, metadata consistency, attach/mount behavior, node failure
recovery, and performance. It must also prove that the object-cache path is
still usable if the filesystem is unavailable. A successful CephFS mount alone
is not an acceptance signal.

Only after that evidence and a reviewed rollback plan may a follow-up change
select RWX for production. The follow-up must retain the old RWO claim until
the new path has converged; PVC replacement and data migration are separate
operations.

## Acceptance and rollback

The Garage/local path is eligible for production consideration only when all
of the following are true:

- two concurrent canaries complete without an attach conflict and without
  mounting `workspace-nix-cache`;
- `prepare-cache` and `promote` see the same disposable `/nix` volume within
  each canary, while concurrent canaries have different stores;
- Garage reads use the Nix substituter and closure writes use the CI writer
  key, with no credential material in logs or manifests;
- cold, warm, and Garage-unavailable timings are recorded against the current
  serialized RWO baseline;
- a failed canary leaves the current tag/adoption path and the RWO fallback
  untouched; and
- the canary remains on Ottawa only. No `nix-cache=true` label is added to
  Robbinsdale.

Rollback is the feature-flag/workflow selection returning to the existing
RWO lane. It must not require deleting a claim, changing a PVC access mode, or
touching Velero resources.

## Follow-up: sandbox substituter

Wiring a sandbox/workspace Nix substituter to the Garage read-only key is
useful, but is independent of this release-capacity experiment. It should be
reviewed as a separate secret-consumption change and must not block the
Garage/local canary. CI continues to use its existing writer key.

## Evidence used for this proposal

- `kubernetes/apps/base/woodpecker/woodpecker/app/workspace-nix-cache-pvc.yaml`
- `kubernetes/apps/base/garage/garage-bucket-ottawa/nix-cache.yaml`
- `docs/reference/nix-binary-cache.md`
- Live Ottawa inventory on 2026-09-18: `workspace-nix-cache` was `Bound` with
  `ReadWriteOnce`; `rook-cephfs` was present with provisioner
  `rook-ceph.cephfs.csi.ceph.com`.

No production object is changed by this proposal.
