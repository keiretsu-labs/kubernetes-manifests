# Garage S3 key-scope inventory

Which workload uses which Garage key and bucket, derived from the manifests
(`kind: GarageKey` CR `bucketPermissions` + the `secretTemplate` name each app
references), not from live cluster state. `owner` implies read+write; the CR
expresses permissions per key×bucket. Re-derive with:

```sh
git grep -l "kind: GarageKey" -- kubernetes/ | while read f; do ...; done
# consumption side: grep the secretTemplate name in the consuming manifests
```

## Per-key scope (key → namespace · buckets → consumer)

| Key (CR ns) | Perm | Bucket(s) | Consumed by (secret name) |
| --- | --- | --- | --- |
| `immich-postgres-key` (immich) | RWO owner | `immich-postgres` | immich s3-backup CronJob → `immich/immich-s3-backup` (ott+rb) |
| `tracearr-postgres-key` (media) | RWO | `tracearr-postgres` | tracearr s3-backup → `media/tracearr-s3-backup` (ott+rb) |
| `bookorbit-postgres-key` (media) | RWO | `bookorbit-postgres` | bookorbit s3-backup → `media/bookorbit-s3-backup` (ott only) |
| `omnibus-postgres-key` (media) | RWO | `omnibus-postgres` | omnibus s3-backup → `media/omnibus-s3-backup` (ott only) |
| `suwayomi-postgres-key` (media) | RWO | `suwayomi-postgres` | suwayomi CNPG → `media/suwayomi-postgres-s3` (ott only) |
| `firefly-postgres-key` (firefly) | RWO | `firefly-postgres` | firefly CNPG → `firefly/firefly-postgres-s3` |
| `forgejo-postgres-key` (forgejo) | RWO | `forgejo-postgres` | forgejo CNPG → `forgejo/forgejo-postgres-s3` |
| `woodpecker-postgres-key` (woodpecker) | RWO | `woodpecker-postgres` | woodpecker CNPG → `woodpecker/woodpecker-postgres-s3` |
| `lobby-postgres-key` (tailscale-pam) | RWO | `lobby-postgres` | lobby CNPG → `tailscale-pam/lobby-postgres-s3` |
| `teslamate-postgres-key` (teslamate) | RWO | `teslamate-postgres` | teslamate CNPG → `teslamate/teslamate-postgres-s3` |
| `bhaiya-postgres-key` (bhaiya) | RWO | `bhaiya-postgres` | pre-provisioned for the foreign bhaiya GitRepository (no in-repo consumer; see architecture.md "bucket but no database") |
| `litellm-postgres-key` (litellm) | RWO | `litellm-postgres` | litellm CNPG → `litellm/litellm-postgres-s3` |
| `kopiur-ottawa-key` (kopiur-system) | RWO | `kopiur-ottawa` | kopiur Repository → `kopiur-system/kopiur-ottawa-s3` |
| `kopiur-robbinsdale-key` (kopiur-system) | RWO | `kopiur-robbinsdale` | kopiur Repository → `kopiur-system/kopiur-robbinsdale-s3` |
| `kopiur-stpetersburg-key` (home-assistant) | RWO | `kopiur-stpetersburg` | kopiur Repository (HA backups) → `home-assistant/kopiur-stpetersburg-s3` |
| `mimir-key` (mimir) | RW | `mimir` | mimir ruler/store → `mimir/mimir-s3` |
| `tailscale-logs-key` (tailscale-system) | RW | `tailscale-logs` | log-streaming CronJob → `tailscale-system/tailscale-logs-s3-auth` |
| `tailscale-recorder-key` (tailscale) | RW | `tailscale-logs` | recorder (config commented out; credential staged) → `tailscale/s3-auth` |
| `tsflow-tailscale-logs-key` (tailscale-examples) | R | `tailscale-logs` | tsflow sandbox → `tailscale-examples/tsflow-tailscale-logs-s3-auth` |
| `nix-cache-writer-key` (woodpecker) | RW | `nix-cache` | Woodpecker CI via its secret store (doc: nix-binary-cache.md) |
| `nix-cache-reader-key` (woodpecker) | R | `nix-cache` | builders, read-only by design |
| `forgejo-key` (forgejo) | RWO | `forgejo` | helmrelease S3 env → `forgejo/garage-s3-auth` |
| `zot-key` (zot) | RWO | `zot` | helmrelease S3 env → `zot/garage-s3-auth` |
| `border0-terraform-key` (garage) | RW | `border0-terraform-state` | imported key; secret lives in `border0-terraform-s3` (SOPS), consumed by border0 terraform runs |
| `webui-sidecar-key` (garage) | RW ×6 | `tracearr-postgres`, `immich-postgres`, `tailscale-logs`, `mimir`, `bookorbit-postgres`, `omnibus-postgres` | garage-webui sidecar envFrom → `garage/garage-webui-sidecar` |

The `garage-bucket-to-*` / `bhaiya-postgres-bucket` objects are
`GarageReferenceGrant`s (namespace reach), not credentials.

## Deployment shape

- **ottawa**: `garage-keys-ottawa` (which layers `garage-keys`) — the full
  set above.
- **robbinsdale / stpetersburg**: `garage-keys` only — the shared backup keys
  (media/immich/mimir/tailscale/bookorbit/omnibus/tracearr). Kopiur keys are
  per-location buckets; webui/nix-cache/border0 are ottawa-scoped by pointer.

## NEEDS-RAJ: over-shared keys

1. **`webui-sidecar-key` is a 6-bucket master**. The garage-webui sidecar
   holds RW (non-owner) on every CNPG backup bucket plus `tailscale-logs` and
   `mimir`. Anyone compromising the webui pod can read or destroy every
   database backup. Finer-grained per-bundle keys — or a read-only variant —
   would shrink that blast radius, at the cost of more secrets for the sidecar
   to switch between. Design change → Raj's call; not patched here.
2. **`bhaiya-postgres-key` has no in-repo consumer.** Intentional per
   architecture.md (foreign pre-provisioning), listed for completeness: if the
   bhaiya side stops using it, the key and bucket are the cleanup surface.
3. **`tailscale-recorder-key`'s consumer is commented out** (recorder.yaml
   storage block). The key/secret still exists; harmless, but it is live
   credential surface without a running consumer — confirm intent or drop the
   key with the feature.

Everything else is 1 key : 1 bucket with least-role shape (backup keys
owner-only on their own bucket; log reader keys read-only). No key grants
`*` or spans namespaces beyond the two cases above.
