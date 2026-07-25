# Runbook — retire the Velero `garage-legacy` location

**Do this on or after 2026-08-24.** Until then, leave it alone.

## Why this exists

Until 2026-07-25 every cluster wrote Velero backups to the `velero` bucket
**root**, because `prefix` sat under `config:` in the HelmRelease where Velero
ignores it. All three clusters therefore shared one kopia repository per
namespace name (`kopia/home` was written by both Ottawa and Robbinsdale), which
is what corrupted indexes and wedged backups.

Fixing the prefix re-pointed each cluster at `<location>/`, which made
backup-sync treat the entire pre-existing catalog as absent from the store and
drop 70 Backup CRs (catalog only — it deletes the CR directly rather than filing
a DeleteBackupRequest, so nothing was purged from S3).

To keep that history restorable, the root `backups/` and `kopia/` trees were
copied to a `legacy/` prefix (9888 objects, 77.4 GiB, verified identical on name
and size) and a **ReadOnly, non-default** `garage-legacy` BSL was pointed at it.
A BSL pointed at the root itself cannot work — Velero rejects it with
`Backup store contains invalid top-level directories: [ottawa robbinsdale]`.

## Why it needs a manual sweep

Velero **will not garbage-collect a read-only location**:

```
Backup cannot be garbage-collected because backup storage location
garage-legacy is currently in read-only mode
```

So expired legacy Backup CRs linger in both clusters' catalogs and the 77.4 GiB
is never reclaimed on its own. ReadOnly is deliberate: making it writable would
have Velero create BackupRepositories and run hourly kopia maintenance against
repos that **both** clusters share — reintroducing the exact two-writer GC
conflict that broke backups in the first place.

The last entry to expire is `bhaiya-raj-trades-*` at 720h TTL, hence 2026-08-24.

## Steps

1. Confirm nothing still needs it — every legacy backup should be past its
   expiration:

   ```bash
   tools/kc.sh ot -n velero-system get backups.velero.io \
     -l velero.io/storage-location=garage-legacy \
     -o custom-columns='NAME:.metadata.name,EXPIRES:.status.expiration' --sort-by=.status.expiration
   ```

2. Remove the `garage-legacy` entry from
   `kubernetes/apps/base/velero/velero/helmrelease.yaml`
   (`configuration.backupStorageLocation`), then `tools/check.sh`, commit, push.

3. Reconcile both clusters and confirm the BSL and its Backup CRs are gone:

   ```bash
   TS=$(date +%s); for c in ot rb; do
     tools/kc.sh $c -n flux-system annotate --overwrite \
       gitrepository/kubernetes-manifests reconcile.fluxcd.io/requestedAt="$TS"
     tools/kc.sh $c -n flux-system annotate --overwrite \
       kustomization/velero reconcile.fluxcd.io/requestedAt="$TS"
   done
   for c in ot rb; do tools/kc.sh $c -n velero-system get bsl; done
   ```

   Backup CRs for a deleted location are not auto-removed; delete the leftovers:

   ```bash
   for c in ot rb; do
     tools/kc.sh $c -n velero-system get backups.velero.io \
       -l velero.io/storage-location=garage-legacy --no-headers \
       | awk '{print $1}' | tr '\n' ' ' \
       | xargs -r tools/kc.sh $c -n velero-system delete backups.velero.io --wait=false
   done
   ```

4. Delete the data. Credentials come from the `velero-credentials` secret; write
   them to a file outside the repo and remove it afterwards.

   ```bash
   tools/kc.sh ot -n velero-system get secret velero-credentials \
     -o jsonpath='{.data.cloud}' | base64 -d > /tmp/gc && chmod 600 /tmp/gc
   g() { env -u AWS_PROFILE AWS_CONFIG_FILE=/dev/null \
     AWS_SHARED_CREDENTIALS_FILE=/tmp/gc AWS_REGION=garage \
     aws --endpoint-url http://ottawa-garage.keiretsu.ts.net:3900 "$@"; }
   g s3 ls s3://velero/legacy/ --recursive --summarize | tail -2   # sanity-check size first
   g s3 rm s3://velero/legacy/ --recursive
   g s3 ls s3://velero/                                            # expect only ottawa/ robbinsdale/
   shred -u /tmp/gc
   ```

5. Delete this runbook and the `garage-legacy` comment block in the HelmRelease.

## Garage S3 gotchas (if you ever copy these trees again)

- `GetObjectTagging` is **NotImplemented** — `aws s3 sync`/`cp` must be given
  `--copy-props none` or every single object fails.
- Server-side multipart `UploadPartCopy` is flaky on large objects
  (`NoSuchUpload` / `InvalidPart`). One 22 MB blob had to be moved with a plain
  download + re-upload.
- Verify with a name+size diff of recursive listings, not object counts alone.
