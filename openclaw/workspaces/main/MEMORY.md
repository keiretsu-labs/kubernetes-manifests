# Operational Memory

Curated knowledge from past sessions. Update when you learn something that saves time next session. Don't log session-specific context — only stable patterns.

## Known Gotchas

- Container name is `openclaw`, never `main` — all kubectl `-c` flags must use `openclaw`
- Flux postBuild eats `${VAR}` — escape as `$${VAR}` in repo files
- ConfigMap subPath mount causes EBUSY on atomic writes — config is copied to emptyDir by init container
- Zot rejects `docker push` and `crane push` — only `skopeo copy docker-archive:` works
- Workspace files from OCI ImageVolume are root-owned — init container runs `chown -R 1000:1000`
- `:latest` image tags are cached by kubelet — must `rollout restart` to pick up new builds
- Always `rm -rf` clone directories before `git clone` — stale clones cause wrong branch/state
- Always `mkdir -p /tmp/outputs` before writing artifacts
- Always use `--context <ctx>` with kubectl — never rely on current-context across clusters
- `sessions_list` and `sessions_history` are OpenClaw built-in tool calls, NOT bash commands
- After `kubectl rollout restart`, wait for `rollout status` before checking logs (10-30s)
- Browser screenshots for Discord: use `action: screenshot` (real PNG), NOT `action: snapshot` (text/aria)
- If `git push` fails with 403, verify GITHUB_TOKEN is set and has push access
- **NEVER commit secrets, credentials, or API keys in plain text to git** — use SOPS for secrets or reference existing cluster secrets instead

## Cluster Quick Facts

- Ottawa: Talos Linux, 3 nodes (rei, asuka, kaji), Rook-Ceph 3 OSDs — media cluster
- Robbinsdale: Talos Linux, 5 nodes (silver, stone, tank, titan, vault), Rook-Ceph 5 OSDs — primary production
- StPetersburg: K3s, GPU-enabled, local-path-provisioner — AI/ML only
- Ceph health warnings after node restarts are transient — wait 5m before escalating
- Flux source-controller can lag webhook delivery — force reconcile if revision is stale
- StPetersburg uses K3s (not Talos) — different upgrade/debug workflow

## API Key Resolution

- Known providers (openai): auto-resolve from env vars by name
- Custom providers (aperture): need explicit `${VAR}` in config apiKey field
- Auth profiles override everything: `~/.openclaw/agents/<id>/agent/auth-profiles.json`

## Cron System

- Jobs persist at `~/.openclaw/cron/jobs.json` on PVC
- Init container refreshes from ConfigMap on every restart
- Schedule kinds: `at`, `every`, `cron` — all require `tz` field

## Validation Pitfalls

- `kustomize build` fails silently on missing files — always cross-check `resources[]` against actual files
- `configMapGenerator` files list must include `cron-jobs.json` alongside `openclaw.json`
- YAML anchors in deployment.yaml don't survive kustomize — use explicit values

## Config Escaping

- Flux postBuild substitutes all `${VAR}` — repo files must use `$${VAR}` for OpenClaw's own env resolution
- Double-check all `apiKey` fields in openclaw.json for correct escaping after edits

## SOPS Credential Patterns

- **PGP key:** `FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5` — stored in `sops-gpg` Secret per cluster
- **Cross-cluster secrets:** `clusters/common/flux/vars/common-secrets.sops.yaml`
- **Per-cluster secrets:** `clusters/talos-*/flux/vars/cluster-secrets.sops.yaml`
- **Substitution chain:** SOPS → Flux decrypts → K8s Secret → postBuild replaces `${VAR}`
- See `skills/sops-credentials/SKILL.md` for full reference

## Container Facts

- Main container: `openclaw` (not `main`)
- Sidecar containers: `tailscale` (networking), `scrapling` (MCP server on localhost:8000)
- Init containers: `sysctler`, `init-workspace`, `init-extensions`
- Config path: `/home/node/.openclaw/clawdbot.json` (emptyDir, writable)
- Workspace path: `/home/node/.openclaw/workspaces/main/`

## CI Patterns

- Push method: `skopeo copy docker-archive:` only (Zot rejects docker push)
- Multi-arch: `crane index append` after per-arch skopeo pushes
- Base image: `ghcr.io/openclaw/openclaw:2026.2.9`

## Alert Handling

AlertManager messages include cluster in `cluster` label — use it as kubectl context directly:

```bash
CLUSTER=$(echo "$ALERT_JSON" | jq -r '.labels.cluster')
kubectl --context=$CLUSTER get pods -n <ns>
```

Available contexts: `ottawa`, `robbinsdale`, `stpetersburg`

| Alert | Diagnostic | Common Cause |
|-------|------------|--------------|
| PrometheusTargetDown | Check endpoints/serviceMonitor config | Stale static IPs |
| SmartDeviceHighTemperature | Check smartctl-exporter, node hardware | Real temp or sensor |
| PodCrashLoopBackOff | `kubectl describe pod`, check logs | App error, OOM, liveness probe |
| FluxReconcileFailure | `flux get kustomization`, check events | Git issue, SOPS decrypt fail |

## Review and Session Patterns

- Pass `includeTools: true` to `sessions_history` to see tool call errors
- Use `activeMinutes: 1440` for 24-hour lookback
- Write session review findings to `/tmp/outputs/session-review.md`
- Max 2 PRs per session — more creates review fatigue
- Always `gh pr list --author rajsinghtechbot --state open` before creating new PRs
- Config changes require pod restart (init container copies on startup)
- Workspace changes require workspace image rebuild (build-workspace.yaml CI)
- Dockerfile.openclaw changes require openclaw image rebuild (build-openclaw.yaml CI)
- **Always scan diff for secrets before pushing** — check for hardcoded passwords, API keys, tokens. Use `git diff` and grep for patterns like `password:`, `secret:`, `key:`, `token:`, `AKIA...`, `ghp...`, `postgres://.*@`

## Skill Design Patterns

- **Descriptions are routing logic** — write them as decision boundaries, not marketing copy
- **Negative examples reduce misfires** — always include "Don't use when..." with what to use instead
- **Templates inside skills are free when unused** — put report/PR templates inside the skill
- **Design for compaction** — write intermediate findings to `/tmp/outputs/` before they're compacted
- **Artifact handoff via standard paths** — use `/tmp/outputs/<task>.md` for inter-step artifacts
