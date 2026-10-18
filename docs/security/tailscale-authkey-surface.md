# Tailscale auth-key surface (2026-10-18)

Findings-only: where Tailscale auth keys / OAuth secrets are configured, their
expiry and reusability posture, and what (if anything) needs operator action.
No change.

## Where keys live in git

| Consumer | Secret | Key material | Source |
|---|---|---|---|
| `tailscale-system` DS + statefulset consumers | `ts-authkey`, `ts-oauth` | `TS_AUTHKEY` (one-shot), `TS_AUTHKEY{,_EPHEMERAL}` derived from **OAuth client secret** `?ephemeral=&preauthorized=true` | `${TS_AUTHKEY}`, `${TS_OAUTH_CLIENT_ID/SECRET}` from cluster-secrets (SOPS) |
| tailscale-examples sandbox (derper, golink, sidecars, tsidp, tsk9s) | per-app Secrets | `TS_AUTHKEY` refs | same SOTS vars |
| tailscale-pam lobby | STS | `TS_AUTHKEY` ref | same |
| operator (helmrelease) | `operator-oauth` | `client_id`/`client_secret` — **OAuth, not authkey**: does not expire like keys | `${TS_OAUTH_CLIENT_*}` |
| tailscale-csi-provider | SecretProviderClass → ts creds | vaulted via CSI | cluster secrets |

19 files reference `TS_AUTHKEY`; every one pulls from a Secret fed by the
Flux `${VAR}` substitution chain — **no authkey literal is committed anywhere**
(SOPS bundles hold the values; `keys.tsauth`-style plaintext absent).

## Expiry / reuse posture

- **Generator**: `tailscale/scripts/create-auth-key.sh` — the only place
  expiry is set: `"expirySeconds": 7776000` = **90 days**, `reusable`
  default **false** (arg 6), `ephemeral`/`preauthorized` per args. Keys are
  generated on demand per tag; nothing in CI/cron mints or rotates them.
- **Runtime keys are OAuth-derived** (`ts-oauth` Secret → `?ephemeral=…
  &preauthorized=true` query form). OAuth client secrets do not carry the
  90-day key expiry; they are the long-lived factor and are rotated as
  cluster secrets, not by this script.
- **No expiry < 30d anywhere in git**: the single hardcoded TTL is 90d; no
  cron/CI checks key age; no `keys.expiry` fields in manifests.

## Findings

| # | sev | observation |
|---|---|---|
| T1 | Info | Two-tier design is sound: one-shot 90d authkeys for bootstrap (reusable=false default), OAuth client secret for the operator + derived ephemeral/preauth keys. Nothing short-lived (<30d) exists to flag. |
| T2 | **NEEDS-RAJ (low)** | **No rotation automation**: `create-auth-key.sh` is manual; if the `ts-authkey` Secret value ages out mid-rollout, new replicas fail auth until a human mints a fresh key into cluster-secrets. Acceptable for the fleet size; if Raj wants, a quarterly `keys.tsauth` rotation reminder (or expiry-check in the live audit workflow) closes it. Not a PR — operator cadence. |
| T3 | Info | `reusable` stays false by default and no manifest/CI passes `true` — no shared-reuse blast radius. The derived `?preauthorized=true` query keys are per-consumer and ephemeral-flagged where intended. |
| T4 | Info | OAuth client secret is the single long-lived credential (operator + derived authkeys). Its rotation is a cluster-secrets edit + reconcile; already covered by immutable-secret rotation doc pattern (new name + ref swap) if ever needed. |

**Verdict: no-finding requiring a PR; T2 recorded as NEEDS-RAJ (rotation
cadence decision), everything else Info.**

Re-derive:

```sh
git grep -n "expirySeconds\|reusable" -- tailscale/scripts/
git grep -l "TS_AUTHKEY" -- kubernetes | grep -v sops | wc -l
git grep -n "TS_OAUTH" -- kubernetes | grep -v sops | head
```
