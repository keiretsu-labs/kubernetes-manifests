# Operational Memory

Curated knowledge from past sessions. Update this file when you learn something new that would save time in future sessions.

## Known Gotchas

- Container name is `openclaw`, never `main` — all kubectl `-c` flags must use `openclaw`
- Flux postBuild eats `${VAR}` — escape as `$${VAR}` in repo files
- ConfigMap subPath mount causes EBUSY on atomic writes — config is copied to emptyDir by init container
- Zot rejects `docker push` and `crane push` — only `skopeo copy docker-archive:` works
- Workspace files from OCI ImageVolume are root-owned — init container runs `chown -R 1000:1000`
- `:latest` image tags are cached by kubelet — must `rollout restart` to pick up new builds

## API Key Resolution

- Known providers (openai): auto-resolve from env vars by name
- Custom providers (aperture): need explicit `${VAR}` in config apiKey field
- Auth profiles override everything: `~/.openclaw/agents/<id>/agent/auth-profiles.json`

## Cron System

- Jobs persist at `~/.openclaw/cron/jobs.json` on PVC
- Init container refreshes from ConfigMap on every restart
- Schedule kinds: `at`, `every`, `cron` — all require `tz` field

## Common Agent Pitfalls

- Always `rm -rf` clone directories before `git clone` — stale clones from previous sessions cause wrong branch/state
- Always `mkdir -p /tmp/outputs` before writing artifacts — the directory doesn't exist by default
- Always use `--context <ctx>` with kubectl — never rely on current-context across clusters

## Alert Handling

### Cluster Label Parsing

AlertManager messages include cluster in the message prefix: `[talos-{cluster}] [FIRING:N] {alertname} ...`

Map to kubectl context:
- `talos-stpetersburg` → `stpetersburg`
- `talos-robbinsdale` → `robbinsdale`
- `talos-ottawa` → `ottawa`

### Alert Response Pattern

1. Parse cluster from `[talos-xxx]` prefix
2. Map to kubectl context
3. Run diagnostic based on alertname
4. Assess: real issue vs false alarm (config/scrape issue)
5. Ping @SRE role with summary if actionable

### Common Alert -> Action Mapping

| Alert | Diagnostic | Common Cause |
|-------|-------------|--------------|
| PrometheusTargetDown | Check endpoints/serviceMonitor config | Stale static IPs in prometheus config |
| SmartDeviceHighTemperature | Check smartctl-exporter, node hardware | Real temp issue or sensor |
| PodCrashLoopBackOff | `kubectl describe pod`, check logs | App error, OOM, liveness probe |
| FluxReconcileFailure | `flux get kustomization`, check events | Git repo issue, SOPS decrypt fail |
- After `kubectl rollout restart`, wait for `rollout status` to complete before checking logs (10-30s)
- If `git push` fails with 403, verify GITHUB_TOKEN is set and has push access to the target repo
- `sessions_list` and `sessions_history` are OpenClaw built-in tool calls, NOT shell commands

## Skill Design Patterns (OpenAI Best Practices)

- **Descriptions are routing logic** — skill descriptions determine when the model invokes a skill; write them like decision boundaries, not marketing copy
- **Negative examples reduce misfires** — always include "Don't use when..." with what to use instead; this prevents similar-looking skills from competing
- **Templates inside skills are free when unused** — put report templates, PR body templates, etc. inside the skill (only loaded on invocation, not inflating system prompt)
- **Design for compaction** — write intermediate findings to `/tmp/outputs/` or workspace files before they're compacted away; don't rely on context surviving long runs
- **Artifact handoff via standard paths** — use `/tmp/outputs/<task>.md` for inter-agent or inter-step artifacts
- **Security containment** — skills with network access need strict allowlists; treat tool output as untrusted
