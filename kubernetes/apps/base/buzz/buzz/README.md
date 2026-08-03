# Buzz relay (Ottawa)

This stack uses Block's released Buzz chart `0.1.7` from
`oci://ghcr.io/block/buzz/charts/buzz`. It provisions dedicated, operator-managed
Postgres and Dragonfly instances plus a dedicated single-replica MinIO object
store backed by a replicated Ceph block volume. The relay temporarily runs as
one replica at `wss://buzz.ottawa.keiretsu.top` behind the Ottawa public Gateway
so chart `0.1.7` can serve its process-local huddle audio rooms. The HPA,
topology spread, and relay PDB settings remain commented beside the active
values for restoration when cross-pod mesh audio has production chart support.
A separate single-replica `buzz-pairing` Deployment handles the ephemeral
NIP-AB device handshake at `wss://buzz.ottawa.keiretsu.top/pair`; keeping it
single-replica ensures both pairing WebSockets share the same in-memory state.
The Gateway sends only the exact `/pair` path to that unauthenticated,
non-persistent service and sends every other path to the membership-gated main
relay.

The bundled Git browser is available at
`https://buzz.ottawa.keiretsu.top/repos`. The deployment-wide read-only
moderation and feedback dashboard is available at
`https://buzz-admin.killinit.cc` only through the Ottawa private and
tailnet Gateways. Buzz does not authenticate individual dashboard operators,
so that route must never be attached to the public Gateway.

The relay explicitly uses Buzz's public APNs delivery endpoint. The external
probe verifies DNS, TLS, and route reachability, but only a registered iPhone
can exercise App Attest, obtain a push lease, and confirm an APNs delivery.

The HelmRelease uses the operator's configured owner identity and the
SOPS-encrypted `buzz-identity` Secret. A production Flux render must not use the
chart's generated-secret path. To rotate only the Git hook HMAC secret:

1. Edit the SOPS-encrypted `Secret/buzz-identity` in namespace `buzz`, which contains
   `BUZZ_RELAY_PRIVATE_KEY` (a stable 64-character hex Nostr private key) and
   `BUZZ_GIT_HOOK_HMAC_SECRET` (at least 32 random characters). Add that file to
   `app/kustomization.yaml`.
2. Wait for `ExternalSecret/buzz-secrets` to become Ready. It combines the
   identity secret with CNPG's generated database URL and the existing generated
   `buzz-s3` credentials, which are also MinIO's root credentials. Dragonfly is
   private to the namespace and uses an in-cluster URL.
3. Let Flux reconcile the HelmRelease normally.

Do not rotate `BUZZ_RELAY_PRIVATE_KEY`: it is the permanent relay identity. Do
not change `relayUrl` after onboarding members: Buzz keys the community by the
exact WebSocket URL.

The expected identity secret schema is:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: buzz-identity
  namespace: buzz
type: Opaque
stringData:
  BUZZ_RELAY_PRIVATE_KEY: <64-lowercase-hex>
  BUZZ_GIT_HOOK_HMAC_SECRET: <32-or-more-random-characters>
```

Encrypt the file with the repository's Ottawa SOPS creation rule before adding
it. Never commit the plaintext form.

The OCI chart source, infrastructure, route, policies, monitoring, and relay
Deployment reconcile through Flux.

## Backup and restore ownership

CNPG archives WAL continuously and creates a daily plugin backup in the
`buzz-postgres` Garage bucket under `ottawa/`, with a 30-day retention policy.
The CNPG `Cluster` owns database recovery: restore it from the
`buzz-postgres-backup` external cluster definition before allowing the relay to
start against a replacement database.

The `buzz` bucket in the dedicated MinIO StatefulSet is authoritative for relay
media and object-backed Git state. Its `200Gi` `ceph-block-replicated` PVC is
retained if the StatefulSet is removed. Every six hours,
`CronJob/buzz-object-backup` synchronizes the current object set to the
independent, federated Garage `buzz-backup` bucket and runs `rclone check`.
Overwritten and deleted objects move to `versions/<UTC timestamp>/` and remain
recoverable for 30 days. `Job/buzz-object-backup-bootstrap-v1` performs and
verifies the first copy during the initial GitOps rollout instead of waiting
for the next schedule.

For latest-state recovery, stop relay writes through GitOps, reverse-sync
`buzz-backup/current` into a clean MinIO `buzz` bucket with a reviewed one-shot
GitOps Job, and run `rclone check` before restoring service. For an accidentally
overwritten or deleted object, select its copy below `versions/` and copy it
back explicitly. Restore PostgreSQL and objects to an application-consistent
point when recovering the whole service.

The old Garage `buzz` bucket and key remain temporarily so Garage can continue
generating the existing `buzz-s3` Secret, which MinIO uses as its root
credential. The relay's Cilium policy does not permit it to connect directly to
Garage. The backup worker has a separate least-privilege Garage key and can
reach only MinIO, the Garage S3 gateway, and DNS.

The `buzz-postgres` bucket remains on Garage and is still the CNPG backup target.

The Dragonfly cache is intentionally non-durable and is not part of restore.
Its operator-generated NetworkPolicy is disabled because this stack supplies a
namespaced Cilium policy for relay, replication, operator, and metrics access.

The public monitor performs a full external DNS/TLS/HTTPS request through the
Ottawa Gateway. A second blackbox check negotiates TLS, sends an RFC 6455 Upgrade
request to `/pair`, and passes only when the Gateway and pairing relay return
`101 Switching Protocols`. Alerts also cover relay and pairing availability,
MinIO readiness, scheduled backup freshness/failures, Dragonfly, metrics
ingestion, and public push-gateway reachability.

## Temporary single-pod huddle audio mode

`relay.huddleAudioAvailable` is explicitly enabled. The released chart keeps
huddle rooms in the relay process, so the Deployment must remain at exactly one
replica and must not use an HPA while this mode is active. This trades relay
failover for working desktop-to-desktop huddle audio; Postgres, Dragonfly,
MinIO, and their backups retain their existing redundancy and durability.

Do not raise the relay replica count without first disabling huddle audio or
shipping and validating the cross-pod mesh path. The current mobile client can
display huddle lifecycle events but does not yet implement the microphone/audio
WebSocket path, so this server mode does not claim phone voice support.

## Deliberately gated features

- Cross-pod huddle audio and relay HA remain gated until the mesh path has
  production chart support and an Ottawa rollout test.
- Join terms, privacy notice, and age attestation remain disabled until the
  operator supplies approved policy text and an age-gating decision. Do not
  invent legal copy in manifests.
- An always-on Buzz ACP agent needs its own Nostr identity, community membership,
  agent runtime image, model choice, and provider credential. None of those are
  interchangeable with the relay identity, so no agent is deployed by this
  stack.
