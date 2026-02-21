# Playbook

Decision frameworks for common situations. Check here before acting.

## Alert Triage

### Ping @SRE immediately
- CrashLoopBackOff with > 3 restarts in 10 minutes
- Flux reconciliation stuck > 15 minutes
- Ceph health CRITICAL (not WARNING)
- Node unreachable
- Storage OSD down

### Open a PR, don't ping
- Manifest misconfiguration found during audit
- Workspace improvement identified
- New alert pattern worth documenting

### Wait and watch (don't act yet)
- Ceph health WARNING after node restart → wait 5 minutes
- Single pod restart → check logs, wait for self-healing
- Flux lag after push → wait 2 minutes, then force reconcile

### Skip entirely
- Transient network blip (< 1 packet loss)
- Prometheus scrape gap < 2 minutes

---

## When to PR vs. Push Directly

### Always open a PR
- Changes to `openclaw.json` or `deployment.yaml`
- New or modified skills
- Any change to `kustomization.yaml`

### Push to branch and self-merge after quick check
- `MEMORY.md` updates
- `TOOLS.md` additions
- `BRAIN.md` updates

---

## Debug Chain

Follow in order — don't skip steps:

1. `flux get kustomization -A` — is GitOps delivering?
2. `kubectl get pods -n <ns>` — is the app running?
3. `kubectl describe pod <name>` — what's the failure reason?
4. `kubectl logs <pod> -c <container>` — what does the app say?
5. `kubectl get events -n <ns> --sort-by='.lastTimestamp'` — cluster-level signals?

---

## PR Conventions

- Branch: `fix/<cluster>-<issue>`, `feat/<scope>-<description>`, `workspace/<topic>-YYYY-MM-DD`
- Always `gh pr list --author rajsinghtechbot --state open` before creating — avoid duplicates
- Max 2 PRs per session
- Never push to main directly
- Never touch SOPS-encrypted files

---

## Code Review Priorities

1. Security: credential exposure, injection risks, hardcoded secrets
2. Correctness: container names, mount paths, image refs, config keys
3. Consistency: cross-file references match (AGENTS.md ↔ deployment.yaml ↔ openclaw.json)
4. Style: conventional commits, minimal diffs

---

## Session Review (daily cron)

1. `sessions_list` with `activeMinutes: 1440` — last 24 hours
2. `sessions_history` with `includeTools: true` — see tool errors
3. Write findings to `/tmp/outputs/session-review.md`
4. Open PRs for actionable improvements (max 2)
