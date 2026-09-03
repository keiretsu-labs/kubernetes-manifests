# Ottawa CephFS RWX probe

This is a deliberately disposable Phase 2 probe for the Ottawa `rook-cephfs`
StorageClass. It is not a service and must not become one. The claim is `3Gi`
and `ReadWriteMany`: that is a few GiB so two concurrent `482 MiB` test files,
the small-file corpus, and filesystem overhead fit with headroom, while making
the non-production intent obvious.

## What it proves

The two Deployment replicas require different nodes (and explicitly exclude
`shiro`) while mounting the same claim. Each pod writes a marker and waits for
the other marker, writes 2,000 unique 4 KiB files using temp-file rename into
place, appends records to a shared journal, writes and hashes a 482 MiB file,
then deletes the test files. The shared journal is checked for all records from
both writers, which tests concurrent visibility and detects lost appends. The
probe prints measured small-file and sequential throughput plus average
per-file latency in its pod logs.

The first revision leaves both pods ready after the workload. Change the
`cephfs-proof.keiretsu.top/rollout` value in the Deployment pod template through
GitOps for the second revision. The resulting replacement pods validate the
marker from the first revision after a fresh volume mount and report
`remount-validated`. This two-revision sequence is intentional: a container
restart alone would not prove a CSI unmount/remount.

The phase request supplies the current Garage S3 comparison points: about
`42 ms` average HTTP latency and `47 MiB/s` registry reads. Record those beside
the probe's `MEASURE` lines in the recovery findings file; they are comparison
baselines, not measurements made by this probe.

## Failure behavior boundary

This probe does not interrupt Ceph, a monitor, an MDS, an OSD, or a node. It can
show the mounted-pod behavior only for faults that occur naturally during the
run. A brief forced volume outage would require an authorized failure
experiment; without one, do not claim a result. Reasonably, a mounted process
may block or return I/O errors while the kernel/CSI path recovers, and a fresh
mount should depend on the CephFS and CSI control plane being available.

## Teardown

After measurements and review, remove `./cephfs-proof` from
`kubernetes/apps/ottawa/kustomization.yaml` in a follow-up GitOps commit (or
remove the `cephfs-proof` pointer directory). The child Kustomization has
`prune: true`, so Flux removes the Deployment and ConfigMap; deleting the
probe namespace removes the PVC and its `Delete`-policy CephFS subvolume. Verify
with read-only `tools/kc.sh ot get pvc -n cephfs-proof` and
`tools/kc.sh ot get pods -n cephfs-proof` after reconciliation. Do not manually
delete production objects.
