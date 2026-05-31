# St. Petersburg recovery checklist

Tracking the GitOps changes made while **talos-stpetersburg was down** that must be
reverted/re-enabled once it is back online and healthy. Created during the 2026-05-31
garage gateway-403 incident.

## Background

stpetersburg going down exposed a latent garage-operator bug: in a unified
storage+gateway Auto-mode cluster the operator (v0.6.5) never layout-assigns the
gateway pods, so their local `key_table` is empty and S3 sig-auth (`get_local`)
returns `403 No such key` / `Access Denied`. With stp up, its gateway masked the
issue; with it down, ~50–100% of S3 requests failed. The durable fix was to point
all S3 clients at the cluster-local **storage** Service (`garage.garage.svc.cluster.local:3900`,
selector `tier:storage`) instead of any gateway endpoint. Storage pods are always in
the layout and always hold the full FullReplication key_table.

Upstream issue: rajsinghtech/garage-operator#209 (operator should layout-assign
gateways in unified Auto mode). The storage-Service redirect below is the workaround;
keep it even after stp returns — it is strictly more reliable than the gateway path.

## KEEP (do NOT revert — these are correct permanently)

- **742786ad3** — S3 clients (loki, mimir, zot, forgejo, plex, hermes, assistant-raj,
  common mimir-key) point at `garage.garage.svc.cluster.local:3900`.
- **0fe403407** — stpetersburg home-assistant + music-assistant StorageStacks point at
  the storage Service.
- **57ed17ab7** — `COMMON_S3_ENDPOINT` overridden to the storage Service in all three
  clusters' plaintext `cluster-settings` ConfigMaps (overrides the SOPS
  `common-secrets` value, which still points at `garage-gw.keiretsu.ts.net`).
  - Optional cleanup when someone has the SOPS PGP key: set `COMMON_S3_ENDPOINT`
    directly in `clusters/common/flux/vars/common-secrets.sops.yaml` to
    `garage.garage.svc.cluster.local:3900` and drop the three cluster-settings
    overrides. Not required — the overrides are harmless and correct.

## REVERT when stpetersburg is back online + healthy

1. **zot cluster membership** (commit 4d54ed810):
   re-add `"stpetersburg-zot:5000"` to the `cluster.members` list in
   `clusters/common/apps/zot/app/helmrelease.yaml` to restore the full 3-way
   consistent-hash ring. zot cluster mode SHARDS repos across members (no failover),
   so while stp is removed its share of repos is served by the 2 live members from the
   shared garage S3 backend. After re-adding: `flux reconcile helmrelease zot -n zot`
   on each cluster; verify `cat /etc/zot/config.json` shows 3 members and that image
   pulls still return 200.
   - This is a `clusters/common/` change → redeploys zot on ALL clusters. Safe: zot
     data lives in garage S3, the restart is stateless.

## Live-only remediation applied during the incident (NOT in git — informational)

These were ephemeral runtime fixes; they need no revert and Flux will not fight them:

- **StorageStack s3Endpoint** was cleared live on ~48 instances so kro re-defaulted
  them to the storage Service (the old `garage-global`/`garage-gw` value had been
  frozen into each instance spec at creation). Git intentionally omits `s3Endpoint`,
  so kro keeps defaulting correctly — no drift.
- **restic stale locks** cleared via `spec.restic.unlock` on plex (both clusters) and
  homeassistant (robbinsdale) — leftover locks from restore ops during the outage that
  blocked the `forget` step. Backups themselves were already succeeding.

## Verify after stp returns

```bash
export KUBECONFIG=$HOME/.kube/operator-config
for c in ottawa robbinsdale stpetersburg; do
  kubectl --context $c get garagecluster garage -n garage \
    -o jsonpath="$c health={.status.health.healthy} parts={.status.health.partitionsAllOk}\n"
done
# zot 3-member ring + image pulls
flux --context ottawa reconcile helmrelease zot -n zot
# volsync all green (no mover pods in Error, all RS synced <26h)
```
