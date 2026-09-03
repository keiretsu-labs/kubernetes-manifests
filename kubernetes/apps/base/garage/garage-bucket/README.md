# Garage web UI key scope

`webui-sidecar-key` is intentionally limited to these six platform buckets:

- `tracearr-postgres`
- `immich-postgres`
- `tailscale-logs`
- `mimir`
- `bookorbit-postgres`
- `omnibus-postgres`

The key has read and write object permissions with `owner: false`. The web UI
sidecar uses the credential for user-selected bucket object administration:
listing and downloading objects, uploading objects, creating folder markers,
and deleting objects or prefixes. Removing write permission would leave those
controls visible but non-functional, so the hardening boundary is the reviewed
bucket allowlist rather than read-only access.

`velero` is deliberately excluded while the policy decision in
[kubernetes-manifests#2637](https://github.com/keiretsu-labs/kubernetes-manifests/issues/2637)
is open. It is a disaster-recovery bucket and has its own dedicated Velero
credential. `bhaiya-postgres` and `firefly-postgres` are also excluded because
their database backup workloads have dedicated credentials. The live
`git-s3-awslabs-1787539999` bucket has no current repository definition or
consumer evidence, so it is excluded as legacy or generated data.

The allowlist is intentionally Git-managed and fails closed. The admin-token
UI may still show an unlisted bucket's metadata, but the sidecar's object list,
read, upload, folder, and delete operations will fail until a reviewed
`bucketPermissions` entry is added here and reconciled by Flux. Do not generate
this list automatically from all `GarageBucket` objects: doing so would grant
new database or private workspace buckets access without review.
