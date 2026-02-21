---
name: Flux Operations
description: >
  Diagnose and manage Flux CD across all 3 clusters (Ottawa, Robbinsdale,
  StPetersburg). Multi-cluster Flux management including source health,
  kustomization status, HelmRelease debugging, and reconciliation operations.

  Use when: You need to check or fix Flux across multiple clusters, diagnose
  cross-cluster Flux issues, force reconcile across all clusters, or manage
  suspended resources. This is the multi-cluster Flux skill.

  Don't use when: Debugging Flux for the OpenClaw namespace specifically
  (main agent's flux-debugging skill handles that). Don't use for pod-level
  issues after Flux applies successfully (use pod-troubleshooting). Don't
  use for making code/manifest changes (use pr-workflow).

  Outputs: Flux status report across all clusters, or targeted diagnosis
  of a specific Flux failure with remediation commands.
requires: []
---

# Flux Operations

## Routing

### Use This Skill When
- Checking Flux health across all 3 clusters
- A kustomization or HelmRelease is failing on any cluster
- Investigating why a GitOps change isn't being applied
- Force-reconciling resources across clusters
- Debugging SOPS, dependency, or source fetch issues
- Heartbeat health check includes Flux status

### Don't Use This Skill When
- The issue is specifically the OpenClaw pod's Flux kustomization → the main agent has **flux-debugging** for that
- A pod is crashing after Flux successfully applied → use **pod-troubleshooting**
- You need to make manifest changes → use **pr-workflow**
- Ceph/storage is the issue → use **storage-ops**
- You need a full health scan (nodes, pods, certs, etc.) → use **cluster-health**

## Cluster Contexts

⚠️ **Always use `--context <ctx>`** — never rely on current-context.

| Cluster | Context |
|---------|---------|
| Ottawa | `talos-ottawa` |
| Robbinsdale | `talos-robbinsdale` |
| StPetersburg | `talos-stpetersburg` |

## Diagnostic Chain

Run these in order to trace Flux issues from source to workload:

### 1. Sources
```bash
flux --context <ctx> get sources git -A
flux --context <ctx> get sources helm -A
flux --context <ctx> get sources oci -A
```
- Check all sources are fetching successfully
- Note last fetch time — stale fetches (>10m old) indicate connectivity issues

### 2. Kustomizations
```bash
flux --context <ctx> get kustomizations -A
```
- Identify any with `Ready: False`
- Check the `message` field for the error

### 3. HelmReleases
```bash
flux --context <ctx> get helmreleases -A
```
- Identify any with `Ready: False` or `Suspended: True`
- For failed releases: check Helm history with `helm --kube-context <ctx> history <release> -n <ns>`

### 4. Events
```bash
kubectl --context <ctx> get events -n flux-system --sort-by='.lastTimestamp' | tail -30
```
- Look for reconciliation errors, auth failures, or timeout events

## Common Failures

### Stale GitRepository Source
**Symptom:** Source shows old revision, kustomizations not updating
**Diagnosis:**
```bash
flux --context <ctx> get sources git -A
kubectl --context <ctx> describe gitrepository <name> -n flux-system
```
**Fix:** Force reconcile `flux --context <ctx> reconcile source git <name> -n flux-system`

### SOPS Decryption Error
**Symptom:** Kustomization fails with "decryption failed" or "unable to decrypt"
**Diagnosis:**
```bash
flux --context <ctx> get kustomization <name> -n flux-system
kubectl --context <ctx> logs -n flux-system deploy/kustomize-controller --tail=30 | grep -i sops
```
**Fix:** This is a secrets issue — escalate to user. Dyson cannot fix SOPS problems.

### Dependency Not Ready
**Symptom:** Kustomization shows "dependency not ready"
**Diagnosis:**
```bash
flux --context <ctx> get kustomization <name> -A -o json | jq '.items[].spec.dependsOn'
```
**Fix:** Trace the dependency chain and fix the root kustomization first.

### Substitution Variable Missing
**Symptom:** "variable not found" or rendered manifest has literal `${VAR}`
**Diagnosis:**
```bash
kubectl --context <ctx> get configmap -n flux-system cluster-settings -o yaml
kubectl --context <ctx> get configmap -n flux-system common-settings -o yaml
```
**Fix:** Check if the variable is defined in the expected ConfigMap. Open PR to add missing variable.

### HelmRelease Upgrade Failed
**Symptom:** HelmRelease stuck in "upgrade retries exhausted"
**Diagnosis:**
```bash
helm --kube-context <ctx> history <release> -n <ns>
kubectl --context <ctx> describe helmrelease <name> -n <ns>
```
**Fix:** Often resolved by bumping the chart version or fixing values. Open PR with the fix.

## Operations

### Force Reconcile
```bash
# Reconcile a specific kustomization with its source
flux --context <ctx> reconcile kustomization <name> -n flux-system --with-source

# Reconcile all kustomizations
flux --context <ctx> get kustomizations -A --no-header | awk '{print $1, $2}' | while read ns name; do
  flux --context <ctx> reconcile kustomization "$name" -n "$ns"
done
```

### Suspend / Resume
Use sparingly — only for debugging or temporarily blocking reconciliation:
```bash
flux --context <ctx> suspend kustomization <name> -n <ns>
flux --context <ctx> resume kustomization <name> -n <ns>
```

### Check Flux Controllers
```bash
kubectl --context <ctx> get pods -n flux-system
kubectl --context <ctx> logs -n flux-system deploy/source-controller --tail=20
kubectl --context <ctx> logs -n flux-system deploy/kustomize-controller --tail=20
kubectl --context <ctx> logs -n flux-system deploy/helm-controller --tail=20
```

## Compaction Notes

When checking Flux across all 3 clusters:
- `mkdir -p /tmp/outputs` before writing any artifacts
- Write per-cluster findings to `/tmp/outputs/flux-status-<cluster>.md` to preserve state across compaction boundaries.

## Security Notes

- Never expose SOPS keys or decrypted secret content in reports
- Flux controller logs may contain sensitive resource names — sanitize before sharing
- Suspended resources should be resumed promptly — forgotten suspensions cause drift
