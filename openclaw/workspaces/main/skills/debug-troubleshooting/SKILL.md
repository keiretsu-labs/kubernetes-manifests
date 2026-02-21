---
name: Debug Troubleshooting
description: >
  Systematic debugging — reproduce, isolate, trace root cause, verify fix.
  Covers code path tracing, log analysis, binary search for regressions,
  and hypothesis-driven debugging.

  Use when: Something is broken and you need to find the root cause in code
  or configuration. The error is in application logic, a regression was
  introduced, or behavior doesn't match expectations.

  Don't use when: The issue is a pod not starting or crashing (use
  pod-troubleshooting), a Flux reconciliation failure (use flux-debugging),
  a CI pipeline failure (use ci-diagnosis), or a Ceph/storage issue (use
  storage-ops). Don't use for code review of proposed changes (use
  code-review).

  Outputs: Root cause analysis with specific file:line references, a proposed
  fix, and verification steps to confirm the fix works.
requires: [gh, git]
---

# Debug Troubleshooting

## Routing

### Use This Skill When
- An error message needs to be traced to its source in code
- Behavior changed after a commit and you need to find the regression
- Application logic is producing wrong results
- You need to understand a code path to propose a fix
- Someone says "this used to work" or "it's returning the wrong thing"

### Don't Use This Skill When
- Pod is in CrashLoopBackOff or ImagePullBackOff → use **pod-troubleshooting**
- Flux kustomization won't reconcile → use **flux-debugging**
- CI build/push failed → use **ci-diagnosis**
- You're reviewing a PR, not debugging live behavior → use **code-review**
- Ceph is unhealthy or PVCs are stuck → use **storage-ops**
- You need to understand cluster architecture → use **cluster-context**

## Approach

1. **Reproduce** — Understand what's failing and under what conditions
2. **Isolate** — Narrow down to the specific component, file, or line
3. **Root cause** — Find the actual bug, not just the symptom
4. **Fix** — Propose a minimal, targeted fix
5. **Verify** — Explain how to confirm the fix works

## Code Debugging

### Read the error

```bash
# Get error from logs
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --tail=100

# Get error from CI
gh run view <id> --repo rajsinghtech/<repo> --log-failed
```

### Trace the code path

```bash
# Clone and search
git clone https://github.com/rajsinghtech/<repo>.git /tmp/debug
cd /tmp/debug

# Find where the error originates
grep -rn "error message text" .
grep -rn "function_name" .

# For regressions: binary search with git bisect
git bisect start
git bisect bad HEAD
git bisect good <last-known-good-commit>
# Test at each step...
```

### Common patterns

| Symptom | Likely Cause |
|---------|-------------|
| `container "main" not found` | Wrong container name — use `openclaw` |
| `EBUSY: resource busy` | Atomic write on ConfigMap subPath mount |
| `manifest invalid` | Pushed via `docker push` instead of `skopeo` |
| `${VAR}` not resolved | Missing `$${}` escaping for Flux postBuild |
| `command not found` | Tool not in Dockerfile or wrong PATH |

## Infrastructure Debugging

Follow the chain: **Flux source → Kustomization → Deployment → Pod → Container**

```bash
# Flux source
flux get source git -A | grep openclaw

# Kustomization
flux get kustomization -A | grep openclaw

# Pod
kubectl get pods -n openclaw -o wide
kubectl describe pod -l app.kubernetes.io/name=openclaw -n openclaw

# Container logs
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --tail=50
```

## Root Cause Analysis Template

```markdown
## Root Cause Analysis

**Issue:** <one-line description>
**Reported:** <how the issue was discovered>
**Impact:** <what's broken and for whom>

### Timeline
1. <event that triggered the issue>
2. <symptoms observed>
3. <investigation steps taken>

### Root Cause
<specific explanation — file, line, logic error>

### Fix
<minimal change needed — include diff or description>

### Verification
<steps to confirm the fix works>

### Prevention
<what would catch this earlier — test, lint rule, CI check>
```

## Compaction Notes

For long debugging sessions:
- `mkdir -p /tmp/outputs` before writing any artifacts
- Write intermediate findings to `/tmp/outputs/debug-notes.md` as you go
- Record hypotheses tested and eliminated — don't re-test after compaction
- Commit the root cause analysis once found

## Edge Cases

- **Intermittent failures:** Check for race conditions, timing-dependent behavior, resource exhaustion
- **Works locally, fails in cluster:** Check env vars, network policies, volume mounts, DNS resolution
- **Error only in logs, no user-visible symptom:** Still investigate — silent errors become loud failures later
