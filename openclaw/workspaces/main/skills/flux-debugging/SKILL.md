---
name: Flux Debugging
description: >
  Diagnose Flux CD reconciliation failures — stale revisions, failed applies,
  dependency errors, SOPS decrypt failures.

  Use when: A kustomization is not Ready, source shows an old commit, Flux
  events show errors, or changes pushed to git aren't being applied to the
  cluster.

  Don't use when: The pod is crashing after Flux successfully applied (use
  pod-troubleshooting). Don't use for CI build failures (use ci-diagnosis).
  Don't use for registry/image issues (use zot-registry). Don't use for
  deploying new changes step-by-step (use gitops-deploy).

  Outputs: Identified root cause of Flux reconciliation failure with specific
  remediation commands.
requires: [flux, kubectl]
---

# Flux Debugging

## Routing

### Use This Skill When
- `flux get kustomization` shows Ready=False
- Source revision is stale (old commit hash)
- Flux events show reconciliation errors
- Changes pushed to git aren't appearing in the cluster
- SOPS decryption errors in kustomize-controller logs
- Dependency chain is broken

### Don't Use This Skill When
- Pod is crashing (CrashLoopBackOff, OOMKilled) → use **pod-troubleshooting**
- CI workflow failed before Flux gets involved → use **ci-diagnosis**
- Image "manifest invalid" or ImagePullBackOff → use **zot-registry** first
- You're deploying changes and want the full workflow → use **gitops-deploy**
- You need to understand the Flux setup across all 3 clusters → use **flux-ops**
- The pod is Running and healthy but behaving wrong → use **debug-troubleshooting**

## Diagnostic Chain

Always follow this order — each step narrows the problem:

```bash
# 1. Source health — is Flux seeing the latest commit?
flux get sources git -A | grep openclaw

# 2. Kustomization health — did it apply successfully?
flux get kustomizations -A | grep openclaw

# 3. Events — what went wrong?
flux events -A --for Kustomization/openclaw
kubectl get events -n flux-system --sort-by='.lastTimestamp' | tail -20
```

## Decision Tree

| Source Status | Kustomization Status | Problem | Action |
|---------------|---------------------|---------|--------|
| Old revision | any | Stale source | See `failures.md` → Stale Revision |
| Current | Ready=False | Apply error | See `failures.md` → Failed Apply |
| Current | Ready=False (dependency) | Blocked | See `failures.md` → Dependency Not Ready |
| Current | SOPS error | Decrypt failure | See `failures.md` → SOPS Decrypt Error |
| Current | Ready=True | Flux is fine | Problem is elsewhere — try **pod-troubleshooting** |

## Quick Actions

```bash
# Force full reconciliation (source + apply)
flux reconcile kustomization openclaw --with-source

# Suspend for manual debugging
flux suspend kustomization openclaw

# Resume after manual fixes
flux resume kustomization openclaw

# Nuclear: force re-fetch and re-apply everything
flux reconcile kustomization openclaw --with-source --force
```

## Edge Cases

- **Source is current but kustomization hasn't updated:** Kustomize-controller may be overloaded or OOMKilled — check its pod status in flux-system
- **Reconciliation succeeds but changes not visible:** The ConfigMap changed but pod didn't restart — config requires pod restart (init container copies on startup)
- **Intermittent failures:** Network issues between cluster and GitHub — check source-controller logs for transient errors
- **"dependency not ready" loop:** Two kustomizations depending on each other — check for circular dependencies
- **`flux reconcile` hangs or times out:** Flux controllers themselves may be unhealthy — always check controller pods first:
  ```bash
  kubectl get pods -n flux-system
  kubectl logs -n flux-system deploy/kustomize-controller --tail=20
  kubectl logs -n flux-system deploy/source-controller --tail=20
  ```

## Security Notes

- SOPS decrypt errors should be escalated — they indicate key management issues
- Never commit decrypted secrets to fix a SOPS error
- Flux logs may contain resource names and namespace info — don't paste full logs in public channels

## Compaction Notes

For long Flux debugging sessions, `mkdir -p /tmp/outputs` then write intermediate findings to `/tmp/outputs/flux-debug.md`:
- Which sources were checked and their status
- Which kustomizations are failing and why
- What remediation was attempted

For detailed failure diagnosis steps, read `failures.md` in this skill directory.
