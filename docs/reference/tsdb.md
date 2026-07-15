# tsdb database connector (historical reference)

> tsdb is no longer deployed. Retained because the Tailscale ACL/capability
> knowledge is hard-won. If redeployed, it belongs under
> `kubernetes/apps/base/media/media-ottawa/tsdb/` with an Ottawa pointer.

## Deployment shape (as it ran in Ottawa)

- StatefulSet + PVC for tsnet state (`/data/tsdb`), image
  `ghcr.io/tailscale/tsdb:latest`
- Runs as root (`runAsUser: 0`) — tsnet state dir creation requires it
- `serviceAccountName: default` — tsdb manages its own auth via OAuth

## Config (HuJSON) — MUST have all three nested sections

Flat configs silently fail:

```json
{
  "tailscale": { "hostname": "...", "state_dir": "...", "tags": [...],
                 "client_id": "...", "client_secret": "..." },
  "connector": { "admin_port": 8080, "log_level": "info" },
  "databases": { "<db-key>": { "engine": "postgres", "host": "...",
                 "port": 5432, "ca_file": "...", "admin_user": "...",
                 "admin_password": "..." } }
}
```

- OAuth creds MUST be in the config (not env vars) for tags to propagate to
  per-database tsnet servers
- `ca_file` is REQUIRED — cannot be omitted
- Flux variable substitution works in the ConfigMap

## CA certificate handling

- CNPG self-signed CA lives in secret `<cluster>-ca`; rotates ~every 90 days
- Cross-namespace mounting is impossible → **deploy tsdb in the SAME namespace
  as the database** so the CA secret mounts directly

## ACL grant (`tailscale.com/cap/databases`)

**No wildcard support** — `internal/relay_base.go:hasAccess` does EXACT string
matching. `roles` = actual postgres **usernames**; `databases` = actual
database names; `"*"` is a literal string.

```json
"tailscale.com/cap/databases": [{
  "<db-key>": {
    "access": [{"databases": ["postgres", "app"], "roles": ["postgres", "app"]}],
    "engine": "postgres"
  }
}]
```

- `<db-key>` must match the key in the config's `databases` section
- Feature-flagged on the tailnet (`database-capability`)

## CNPG integration notes

- `enableSuperuserAccess: true` creates a superuser secret; if missing, set
  the password manually (`ALTER USER postgres PASSWORD '...'`)
- Barman Cloud plugin TLS errors block CNPG reconciliation — restart
  `barman-cloud` and `cnpg-cloudnative-pg` in cnpg-system
- Stuck backups (empty phase) also block reconciliation — delete them

## Upstream doc gaps (tailscale-www `database-connectors/index.mdx`)

1. `roles` described as "database roles" but matched against postgres
   usernames (`sess.targetUser`)
2. No mention that `*` is not a wildcard (exact match only) — same for
   `databases`
3. No guidance on cross-namespace `ca_file` access (recommend same-namespace)
4. Minimal config example omits required `tailscale`/`connector` sections
5. OAuth-in-config (not env vars) requirement for tags undocumented

## Code pointers

- tsdb source: `~/Documents/GitHub/tsdb/` — capability `pkg/cap.go`, access
  check `internal/relay_base.go` (~443), WhoIs extraction (~409)
- Control validation: `corp/control/policy/tsdb.go` (`verifyTSDBGrant`)
- Feature flag: `corp/control/feature/feature.go` (`DatabaseCapability`)
