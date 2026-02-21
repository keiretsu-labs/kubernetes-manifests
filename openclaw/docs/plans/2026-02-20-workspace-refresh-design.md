# OpenClaw Workspace Refresh — Design

**Date:** 2026-02-20
**Status:** Approved

## Context

The pod recently had a CrashLoopBackOff caused by a stale `clawdbot.json` on the
PVC (from an agent-written commit that was reverted). Gateway is currently up.
This design addresses that fragility plus a range of config drift and operational
gaps found during audit.

---

## Section 1: Config Changes (`kustomization/openclaw.json`)

### 1a. Gateway Trusted Proxies

**Problem:** `[ws] Proxy headers detected from untrusted address` warning in logs.
The HTTPRoute flows: Envoy Gateway pod (10.3.x.x) → ClusterIP → openclaw. Without
`trustedProxies`, gateway can't read real client IP from `X-Forwarded-For` headers.

**Fix:** Add `trustedProxies` using Flux variable substitution:

```json
"gateway": {
  "trustedProxies": ["${CLUSTER_POD_CIDR}", "${CLUSTER_SERVICE_CIDR}"]
}
```

In the repo (double-escaped for Flux): `"$${CLUSTER_POD_CIDR}"`, `"$${CLUSTER_SERVICE_CIDR}"`.

### 1b. Discord DM Policy Schema Migration

**Problem:** Config has `channels.discord.dm.policy` which triggers `openclaw doctor`
migration warning on every start. The doctor migration would be overwritten on next
pod restart by the init container anyway.

**Fix:** Rename the key directly in `kustomization/openclaw.json`:
- `channels.discord.dm.policy` → `channels.discord.dmPolicy`
- Remove the empty `channels.discord.dm` object

### 1c. Enable Web Search

**Problem:** `tools.web.search.enabled: false` but `BRAVE_SEARCH_API_KEY` exists in
the SOPS-encrypted secrets. No documented reason for it being disabled.

**Fix:** Set `tools.web.search.enabled: true`.

---

## Section 2: Deployment Hardening (`kustomization/deployment.yaml`)

### 2a. Readiness Probe

**Problem:** No health probes on the `openclaw` container. Kubernetes marks it
`Ready` immediately on process start, routing traffic before the gateway finishes
binding. During crash recovery, traffic is routed prematurely.

**Fix:** Add readiness probe (TCP check, gateway port):
```yaml
readinessProbe:
  tcpSocket:
    port: 18789
  initialDelaySeconds: 15
  periodSeconds: 10
  failureThreshold: 3
```

A startup probe guards the initialization window:
```yaml
startupProbe:
  tcpSocket:
    port: 18789
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 12  # 60s max startup window
```

### 2b. Pin busybox in Init Container

**Problem:** `busybox:latest` is unpinned; every other image in the deployment is
pinned. Unpinned init containers can silently pick up breaking changes.

**Fix:** `busybox:latest` → `busybox:1.37.0`

### 2c. Config Copy Robustness

**Problem:** Init container uses `cp /opt/config/openclaw.json /home/node/.openclaw/clawdbot.json`.
If the PVC has a stale or corrupted `clawdbot.json` (e.g., from a failed agent commit
that was later reverted), the `cp` may not overwrite correctly due to locks or timing.

**Fix:** Change to explicit remove-then-copy:
```sh
rm -f /home/node/.openclaw/clawdbot.json
cp /opt/config/openclaw.json /home/node/.openclaw/clawdbot.json
```

### 2d. PVC Migration: RBD → CephFS for RollingUpdate Strategy

**Problem:** `strategy.type: Recreate` causes full downtime during every deployment
(config changes, image updates) and also during crash recovery. The reason for
`Recreate` is the `ceph-block-replicated` PVC which is `ReadWriteOnce` (RWO) —
only one pod can mount it at a time, making `RollingUpdate` impossible.

**Fix:** Migrate PVC from `ceph-block-replicated` (RBD, RWO) to `rook-cephfs` (RWX).
CephFS supports multiple concurrent mounts, enabling `RollingUpdate`.

Migration plan:
1. Create new `openclaw-data-cephfs` PVC (5Gi, `rook-cephfs`)
2. Run a migration Job: mount both PVCs, `rsync -a` data from old to new
3. Scale deployment to 0
4. Update `deployment.yaml` to reference `openclaw-data-cephfs`
5. Change `strategy.type: Recreate` → `strategy.type: RollingUpdate` (default)
6. Scale back to 1; verify pod comes up
7. Delete old PVC after verifying stable

**Post-migration:** `strategy.type: RollingUpdate` (default settings):
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```
This ensures: new pod must pass probes before old pod is terminated.

**Note:** PVC `pvc.yaml` manifest also needs to be updated to reference `rook-cephfs`.

---

## Section 3: Workspace Content Refresh

### 3a. Model Reference Drift

All workspace files still reference the old default model `nvidia/moonshotai/kimi-k2.5`.
Actual running config uses `aperture/MiniMax-M2.5` for all agents.

Files to update:
| File | Change |
|------|--------|
| `workspaces/main/MEMORY.md` | `nvidia/moonshotai/kimi-k2.5` → `aperture/MiniMax-M2.5` |
| `workspaces/main/skills/cluster-context/SKILL.md` | Update provider table + inline model refs |
| `workspaces/morty/skills/openclaw-docs/SKILL.md` | Model ref update |
| `workspaces/dyson/skills/cluster-health/SKILL.md` | Model ref update |
| `workspaces/robert/IDENTITY.md` | Model ref update |
| `workspaces/ribak/AGENTS.md` | Model ref update |
| `workspaces/leon/IDENTITY.md` | Update from `anthropic/claude-opus-4-6` → `aperture/MiniMax-M2.5` |
| `workspaces/leon/HEARTBEAT.md` | Update model reference |

### 3b. Agent Tables Across Workspaces

All agent AGENTS.md files have outdated model references and don't include Ribak.

Files to update: `main/AGENTS.md`, `morty/AGENTS.md`, `robert/AGENTS.md`, `dyson/AGENTS.md`

Changes per file:
- Replace `kimi-k2.5` → `MiniMax M2.5` in the model column
- Add Ribak row: `| **Ribak** | ribak | Code review assistant for Leon | MiniMax M2.5 | Leon's sub-agent |`

### 3c. Ribak Code Review Skill

Ribak is described as Leon's code review assistant but has only an `openspec` skill.
A `code-review` skill enables Ribak to do structured analysis.

**New file:** `workspaces/ribak/skills/code-review/skill.md`

```markdown
---
name: Code Review
description: >
  Detailed code analysis support for Leon — per-file review, security scan,
  correctness checks, and structured findings output.

  Use when: Leon assigns a PR or file for review, when you need to analyze
  specific changed files in depth, or when producing a findings report that
  Leon will compile into a full PR review.

  Don't use when: The task is architectural design (report back to Leon).
  Don't use for runtime debugging or pod failures. Don't post reviews directly
  to PRs — output findings to /tmp/outputs/ for Leon to review and post.

  Outputs: Findings report at /tmp/outputs/review-<pr-number>.md, grouped
  by severity (Critical/High/Medium/Low).
requires: [gh, git]
---

# Code Review (Ribak)

## Role

You are Leon's analysis sub-agent. Leon delegates specific review tasks to you.
Your job: thorough analysis, structured findings, hand back to Leon.

Do NOT post reviews to GitHub yourself. Write findings to `/tmp/outputs/`
and report back. Leon decides what to post.

## Steps

### 1. Understand the Assignment

Leon will specify:
- The repo and PR number (or branch/diff)
- Which files or areas to focus on
- What type of review (security, correctness, style, infrastructure)

### 2. Get the Diff

```bash
gh pr diff <number> --repo rajsinghtech/<repo>
```

### 3. Review Checklist

**Correctness**
- Logic matches PR description
- Edge cases: nil/null, empty inputs, overflow, concurrency
- Error handling: caught, logged, propagated correctly

**Security**
- No hardcoded secrets, tokens, credentials
- No `${VAR}` patterns that bypass Flux substitution escaping (`$${VAR}` required)
- Input validation on external data
- SOPS files not modified or incorrectly re-encrypted

**Style & Maintainability**
- Follows existing conventions in the repo
- No unnecessary complexity
- Tests present for new logic

**Infrastructure (for K8s/Flux changes)**
- `jq .` / `yq .` valid
- `$${VAR}` Flux escaping correct
- Resource limits set
- Container names correct (`openclaw`, not `main`)

### 4. Output Findings

Write to `/tmp/outputs/review-<pr-number>.md`:

```markdown
## Ribak Analysis: PR #<number>

**Scope:** <what files/areas you reviewed>

### Critical
- <file:line> — <description>

### High
- None

### Medium
- <finding>

### Low
- <nit>

### Security Checklist
- [ ] No hardcoded credentials
- [ ] Flux ${VAR} escaping correct (`$${VAR}` in repo)
- [ ] SOPS files intact
- [ ] Resource limits present
```

Then report back to Leon with a summary and the output file path.
```

---

## Non-Goals

- HA / multi-replica (blocked by stateful agent architecture; PVC migration enables future investigation)
- Tailscale serve / gateway bind mode changes (user explicitly does not want this)
- Network policies (separate concern, out of scope for this refresh)

## Future Improvements (Not In Scope)

- Enable Flux Image Automation Controller for automatic digest pinning
- Add SOPS secret rotation process documentation
- Prometheus ServiceMonitor for gateway metrics
- CronJob for proactive Dyson weekly cluster health summary
