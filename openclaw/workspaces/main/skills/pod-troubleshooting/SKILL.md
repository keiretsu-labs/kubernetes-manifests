---
name: Pod Troubleshooting
description: >
  Debug pod crashes, CrashLoopBackOff, ImagePullBackOff, OOMKilled, init
  container errors, and EBUSY config failures.

  Use when: Pods are not Running, containers are restarting, init containers
  fail, or the pod is Running but the application inside isn't working.

  Don't use when: Flux reconciliation is the problem (use flux-debugging).
  Don't use for registry-level image issues (use zot-registry). Don't use
  for Ceph/storage failures (use storage-ops). Don't use for deploying
  changes (use gitops-deploy).

  Outputs: Diagnosis of why the pod is unhealthy, with specific cause
  identified and remediation steps.
requires: [kubectl]
---

# Pod Troubleshooting

## Routing

### Use This Skill When
- Pod status is not Running (Pending, CrashLoopBackOff, Error, Init:Error)
- Container is restarting repeatedly
- Pod is Running but application isn't responding
- OOMKilled events in pod status
- EBUSY errors in container logs
- Someone says "the bot is down" or "openclaw isn't responding"

### Don't Use This Skill When
- Flux kustomization shows Ready=False → use **flux-debugging**
- Image doesn't exist in registry or "manifest invalid" → use **zot-registry**
- Ceph is unhealthy or PVCs won't bind → use **storage-ops**
- You're deploying new changes → use **gitops-deploy**
- The issue is in application code logic → use **debug-troubleshooting**
- CI pipeline failed → use **ci-diagnosis**

## Diagnostic Chain

```bash
# 1. Pod status overview
kubectl get pods -n openclaw -o wide

# 2. Detailed state for failing pods
kubectl describe pod -l app.kubernetes.io/name=openclaw -n openclaw

# 3. Namespace events
kubectl get events -n openclaw --sort-by='.lastTimestamp' | tail -20
```

## Container Names

Always specify `-c <name>` for logs/exec:

| Container | Role |
|-----------|------|
| `openclaw` | Main OpenClaw server |
| `tailscale` | Tailscale mesh sidecar |
| `init-workspace` | Copies workspace + config to emptyDir |
| `sysctler` | Enables IP forwarding (init) |

⚠️ **Never use `-c main`** — the container is called `openclaw`. This is a common mistake that wastes time.

## Decision Tree

| Symptom | Likely Cause | Action |
|---------|-------------|--------|
| `ImagePullBackOff` | Registry auth or missing tag | See `failures.md` → ImagePullBackOff |
| `CrashLoopBackOff` | Container exits repeatedly | See `failures.md` → CrashLoopBackOff |
| `Init:Error` | Init container failed | See `failures.md` → Init:Error |
| `OOMKilled` | Memory limit exceeded | See `failures.md` → OOMKilled |
| `EBUSY` in logs | Config mounted as subPath | See `failures.md` → EBUSY |
| `Pending` | Scheduling failure | Check events: insufficient resources, node selector, taint |
| Running but unresponsive | App-level issue | Check container logs, then **debug-troubleshooting** |

## Quick Actions

```bash
# Container logs (current)
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --tail=100

# Previous crash logs (the crash that caused the restart)
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --previous --tail=100

# Exec into running container
kubectl exec -it deployment/openclaw -c openclaw -n openclaw -- /bin/sh

# Restart deployment (nuclear option — try diagnosis first)
kubectl rollout restart deployment openclaw -n openclaw
kubectl rollout status deployment openclaw -n openclaw
```

## Escalation Template

When the issue can't be resolved and needs human intervention:

```markdown
## Pod Issue Report

**Status:** <pod status>
**Since:** <when it started>
**Restarts:** <count>

### Symptoms
<what's observed>

### Diagnosis
<what was checked and found>

### Attempted Fixes
1. <action taken> → <result>

### Recommendation
<what needs to happen next>
```

## Edge Cases

- **Pod Running with 0/2 Ready:** Readiness probe failing — check probe config and what it's hitting
- **Terminating stuck:** Finalizers blocking deletion — check `kubectl get pod -o yaml` for finalizers
- **Init container succeeds but main container fails:** Init container may have written bad config — check the emptyDir content
- **Multiple pods (old + new):** Rollout stuck — check `kubectl rollout status` and deployment events

## Compaction Notes

If debugging across a long session:
- `mkdir -p /tmp/outputs` before writing any artifacts
- Write findings to `/tmp/outputs/pod-debug.md` after each diagnostic step
- Record which containers you've checked and what you found
- This prevents re-running the same commands after context compaction

For detailed failure diagnosis steps, read `failures.md` in this skill directory.
