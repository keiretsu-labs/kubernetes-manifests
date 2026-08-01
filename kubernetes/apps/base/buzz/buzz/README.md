# Buzz relay (Ottawa)

This stack uses Block's released Buzz chart `0.1.7` from
`oci://ghcr.io/block/buzz/charts/buzz`. It provisions dedicated, operator-managed
Postgres and Dragonfly instances plus a dedicated single-replica MinIO object
store backed by a replicated Ceph block volume. The relay is configured for two
replicas at `wss://buzz.ottawa.keiretsu.top` behind the Ottawa public Gateway.

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
retained if the StatefulSet is removed. The old Garage `buzz` bucket and key are
temporarily retained so Garage can continue generating the existing `buzz-s3`
Secret without introducing another encrypted credential; Buzz network policy
does not permit the relay to connect to Garage. Database and object data should
be restored to a consistent recovery point when recovering the whole service.

The `buzz-postgres` bucket remains on Garage and is still the CNPG backup target.

The Dragonfly cache is intentionally non-durable and is not part of restore.
Its operator-generated NetworkPolicy is disabled because this stack supplies a
namespaced Cilium policy for relay, replication, operator, and metrics access.

The public monitor performs a full external DNS/TLS/HTTPS request through the
Ottawa Gateway. The repository blackbox-exporter configuration has no WebSocket
upgrade module, so a protocol-level WebSocket handshake check is intentionally
not claimed here.
