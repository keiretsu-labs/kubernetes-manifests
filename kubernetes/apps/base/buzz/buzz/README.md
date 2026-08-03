# Buzz relay (Ottawa)

This stack uses Block's released Buzz chart `0.1.7` from
`oci://ghcr.io/block/buzz/charts/buzz`. It provisions dedicated, operator-managed
Postgres and Dragonfly instances plus a dedicated single-replica MinIO object
store backed by a replicated Ceph block volume. The relay is configured for two
to six replicas (CPU HPA, with a two-replica floor) at
`wss://buzz.ottawa.keiretsu.top` behind the Ottawa public Gateway.
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

## Bhaiya connector administrator

`Job/buzz-bhaiya-connector-bootstrap-v1` uses `/usr/local/bin/buzz-admin` from
the same released, pinned Buzz image as the relay to admit Bhaiya's deployment
connector public key as a community administrator. It reads the existing relay,
database, and Redis settings from `buzz-secrets`; no connector private key is
present in this namespace. Destination and egress policies limit the Job to
Buzz Postgres, Dragonfly, and DNS.

The completed Job is deliberately retained so Flux does not rerun it on every
reconciliation. After restoring Buzz Postgres to a point before connector
enrollment, rename the Job to the next version and let Flux reconcile it. Do
not run `buzz-admin` manually against production.

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
`101 Switching Protocols`. Alerts also cover relay and pairing replicas, HPA
health and saturation, MinIO readiness, scheduled backup freshness/failures,
Dragonfly, metrics ingestion, and public push-gateway reachability.

## Deliberately gated features

- Huddle audio remains unavailable because the released chart supports it only
  for a single relay replica until a production SFU path exists. This deployment
  keeps relay HA and autoscaling instead.
- Join terms, privacy notice, and age attestation remain disabled until the
  operator supplies approved policy text and an age-gating decision. Do not
  invent legal copy in manifests.
- An always-on Buzz ACP agent needs its own Nostr identity, community membership,
  agent runtime image, model choice, and provider credential. None of those are
  interchangeable with the relay identity, so no agent is deployed by this
  stack.
