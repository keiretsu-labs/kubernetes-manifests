---
name: Manifest Lint
description: >
  Validate kustomize build, cross-reference resources, check container names,
  volume mounts, and ConfigMap generators.

  Use when: Any file in kustomization/ was edited and needs validation before
  deploying. Also use for periodic manifest hygiene checks or when kustomize
  build is failing.

  Don't use when: Validating only openclaw.json content (use config-audit).
  Don't use for Flux reconciliation debugging (use flux-debugging). Don't
  use for CI pipeline failures (use ci-diagnosis). Don't use for pod
  runtime issues (use pod-troubleshooting).

  Outputs: Pass/fail validation result with specific errors identified,
  including file and line references for each issue found.
requires: [kustomize, yq, jq]
---

# Manifest Lint

## Routing

### Use This Skill When
- You edited deployment.yaml, kustomization.yaml, pvc.yaml, or any manifest
- `kustomize build` is failing and you need to find out why
- Verifying manifest correctness before pushing changes
- Cross-checking that resource names match between files
- Periodic manifest hygiene audit

### Don't Use This Skill When
- Only openclaw.json config values changed (no manifest changes) → use **config-audit**
- Flux can't reconcile but manifests are valid → use **flux-debugging**
- CI build failed → use **ci-diagnosis**
- Pod is crashing with valid manifests → use **pod-troubleshooting**
- You're making changes, not validating → make changes first, then lint

## Steps

```bash
cd /tmp/oc-audit  # or fresh clone
```

### 1. Kustomize Build
```bash
kustomize build kustomization/
```
If this fails, the error tells you exactly what's wrong (missing resource, bad YAML, etc).

### 2. Check All Resources Listed
```bash
# Resources declared in kustomization.yaml
yq '.resources[]' kustomization/kustomization.yaml

# Files that exist
ls kustomization/*.yaml | grep -v kustomization.yaml | grep -v openclaw.json
```
Every YAML file should be in the resources list (except openclaw.json which is in configMapGenerator).

### 3. Deployment Validation
```bash
# Container names
yq '.spec.template.spec.containers[].name' kustomization/deployment.yaml
# Expected: openclaw, tailscale

# Init container names
yq '.spec.template.spec.initContainers[].name' kustomization/deployment.yaml
# Expected: sysctler, init-workspace

# Volume mounts reference existing volumes
yq '.spec.template.spec.volumes[].name' kustomization/deployment.yaml
```

### 4. Common Mistakes Checklist
- ❌ Container named `main` instead of `openclaw`
- ❌ Missing `imagePullPolicy: Always` on `:latest` tags
- ❌ Volume mount path mismatch between init container and main container
- ❌ Missing resource limits/requests
- ❌ `emptyDir` instead of PVC reference
- ❌ ConfigMap/Secret names don't match what kustomize generates
- ❌ Init container copies to wrong path
- ❌ New YAML file not added to `resources[]` in kustomization.yaml

### 5. Cross-Reference Check
```bash
# ConfigMap name in kustomization.yaml
yq '.configMapGenerator[].name' kustomization/kustomization.yaml

# ConfigMap name referenced in deployment
yq '.spec.template.spec.volumes[] | select(.configMap) | .configMap.name' kustomization/deployment.yaml
```
These must match.

## Validation Report Template

```markdown
## Manifest Lint Report

**Date:** <date>

### Build
- `kustomize build`: ✅ Pass / ❌ Fail (<error>)

### Resources
- All files listed in kustomization.yaml: ✅ / ❌ missing: <file>
- All listed resources exist: ✅ / ❌ extra: <file>

### Deployment
- Container names correct: ✅ / ❌
- Volume mounts valid: ✅ / ❌
- Resource limits set: ✅ / ❌
- Image pull policy correct: ✅ / ❌

### Cross-References
- ConfigMap names match: ✅ / ❌
- Secret names match: ✅ / ❌

### Result: PASS / FAIL (<N> issues)
```

## Edge Cases

- **kustomize build succeeds but output is wrong:** Build passing doesn't mean the rendered output is correct — spot-check the output for expected values
- **YAML anchors:** Kustomize doesn't preserve YAML anchors — use explicit values instead
- **configMapGenerator with cron-jobs.json:** Don't forget this file exists alongside openclaw.json
