---
name: PR Workflow
description: >
  Clone kubernetes-manifests, branch, fix, validate, and open a PR.

  Use when: You've identified an issue in the kubernetes-manifests repo that
  needs fixing — resource limits, HelmRelease values, Flux kustomization
  config, namespace labels, or any manifest change. This is the standard
  workflow for making changes via pull request.

  Don't use when: The change is in openclaw-workspace repo (that's a direct
  push to main, not a PR to kubernetes-manifests). Don't use for diagnosing
  issues (use cluster-health, flux-ops, or storage-ops first, then come here
  to fix). Don't use when you're unsure what to change — diagnose first.

  Outputs: A pull request on rajsinghtech/kubernetes-manifests with validated
  changes, conventional commit message, and descriptive PR body.
requires: []
---

# PR Workflow

## Routing

### Use This Skill When
- You've diagnosed an issue and know the fix involves kubernetes-manifests
- Increasing resource limits for a crashing pod
- Fixing HelmRelease values or version bumps
- Fixing Flux kustomization config (paths, dependencies, substitution vars)
- Adding/modifying namespace labels or annotations
- Someone says "open a PR to fix this"

### Don't Use This Skill When
- The change is to openclaw-workspace repo → commit directly to main
- You haven't diagnosed the issue yet → use **cluster-health**, **flux-ops**, or **storage-ops** first
- You're only inspecting/reading manifests → just use `kubectl` or clone and read
- The issue is with CI workflows → those live in openclaw-workspace, not kubernetes-manifests

## Pre-Flight

Before starting, check for duplicate PRs:
```bash
gh pr list --repo rajsinghtech/kubernetes-manifests --state open
```
If an open PR already addresses this issue, comment on it instead of creating a new one.

## Setup

```bash
# Always clean up stale clones first — leftover state from previous sessions causes confusion
rm -rf /tmp/k8s-manifests
git clone https://github.com/rajsinghtech/kubernetes-manifests.git /tmp/k8s-manifests
cd /tmp/k8s-manifests
```

⚠️ **Always `rm -rf` before cloning.** Stale clones from previous sessions will have the wrong branch, uncommitted changes, or outdated refs.

## Branch Naming

Use conventional branch names:
- `fix/ottawa-<description>` — bug fix for Ottawa cluster
- `fix/robbinsdale-<description>` — bug fix for Robbinsdale
- `fix/stpetersburg-<description>` — bug fix for StPetersburg
- `fix/infra-<description>` — shared infrastructure fix
- `feat/<description>` — new feature or addition
- `chore/<description>` — maintenance, cleanup

```bash
git checkout -b fix/ottawa-coredns-memory-limit
```

## Common Fix Templates

### Resource Limits
```yaml
# Increase memory limit for a crashing pod
resources:
  limits:
    memory: "512Mi"  # was 256Mi, OOMKilled
  requests:
    memory: "256Mi"
```

### Flux Kustomization Config
```yaml
# Fix dependency or path issues
spec:
  dependsOn:
    - name: infrastructure
  path: ./apps/media
  sourceRef:
    kind: GitRepository
    name: flux-system
```

### HelmRelease Version Bump
```yaml
spec:
  chart:
    spec:
      version: ">=1.2.3"  # bump from 1.2.2
```

### HelmRelease Values Fix
```yaml
spec:
  values:
    persistence:
      enabled: true
      storageClass: "ceph-block"  # was wrong class
```

### Namespace Label/Annotation
```yaml
metadata:
  labels:
    istio-injection: enabled  # add missing mesh label
```

## Validate Before Committing

```bash
# Validate YAML syntax
yq . <changed-file.yaml> > /dev/null

# Kustomize build (if applicable)
kustomize build <path-to-kustomization-dir>/ > /dev/null

# Check for common mistakes
grep -rn '<<<' /tmp/k8s-manifests/  # merge conflicts
grep -rn 'TODO\|FIXME\|HACK' <changed-files>  # leftover markers
```

## Commit and Push

```bash
git add <specific-files>
git commit -m "fix(ottawa): increase coredns memory limit to prevent OOM"
git push origin fix/ottawa-coredns-memory-limit
```

Commit message conventions:
- `fix(<scope>)`: bug fix
- `feat(<scope>)`: new feature
- `chore(<scope>)`: maintenance
- Scope: cluster name (`ottawa`, `robbinsdale`, `stpetersburg`) or `infra` for shared

## Create PR

```bash
gh pr create --repo rajsinghtech/kubernetes-manifests \
  --title "fix(ottawa): increase coredns memory limit to prevent OOM" \
  --body "$(cat <<'EOF'
## Problem
CoreDNS pods on Ottawa are OOMKilled with current 256Mi limit.

## Fix
Increased memory limit to 512Mi, request to 256Mi.

## Affected
- Cluster: talos-ottawa
- Namespace: kube-system
- Resource: deployment/coredns
EOF
)"
```

## PR Body Template

```markdown
## Problem
<What's broken and evidence (pod status, error message, alert)>

## Fix
<What was changed and why this specific value/config>

## Affected
- Cluster: <cluster name>
- Namespace: <namespace>
- Resource: <kind/name>

## Validation
- [ ] YAML syntax valid (`yq .`)
- [ ] Kustomize build passes (if applicable)
- [ ] No unrelated changes included
```

## Report Back

After creating the PR, report:
```
[ottawa] PR opened: fix(ottawa): increase coredns memory limit
URL: https://github.com/rajsinghtech/kubernetes-manifests/pull/123
Files changed: apps/kube-system/coredns/deployment.yaml
```

## Rules

- **Never push to main** — always branch and PR
- **Never skip validation** — kustomize build must pass
- **One concern per PR** — don't mix unrelated fixes
- **Include context** — PR body must explain the problem, fix, and affected resources
- **Check for duplicates first** — `gh pr list --repo rajsinghtech/kubernetes-manifests --state open`

## Edge Cases

- **Multiple clusters need the same fix:** One PR per cluster, or one PR if the file is shared
- **Fix requires SOPS changes:** Dyson cannot modify SOPS — escalate to user
- **Unsure about the right value:** State your reasoning in the PR body and request review
