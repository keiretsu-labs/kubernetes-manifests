---
name: CI Diagnosis
description: >
  Diagnose GitHub Actions workflow failures — build errors, skopeo push
  failures, crane manifest issues, workspace build problems.

  Use when: A CI workflow run failed, images aren't updating after a push,
  or someone asks "why did the build fail?" Covers both build-openclaw.yaml
  and build-workspace.yaml pipelines.

  Don't use when: The pod is crashing after a successful CI run (use
  pod-troubleshooting). Don't use for Flux reconciliation issues (use
  flux-debugging). Don't use for registry inspection when CI succeeded
  (use zot-registry). Don't use for code-level bugs (use
  debug-troubleshooting).

  Outputs: Root cause of CI failure with specific step, error message,
  and fix recommendation.
requires: [gh]
---

# CI Diagnosis

## Routing

### Use This Skill When
- GitHub Actions workflow shows ❌ failed
- Images aren't appearing in the registry after a push to main
- Someone asks "why didn't the build go through?"
- Investigating build, push, or manifest creation failures
- A new commit should have triggered CI but didn't

### Don't Use This Skill When
- CI succeeded but pod is crashing → use **pod-troubleshooting**
- CI succeeded but Flux won't reconcile → use **flux-debugging**
- CI succeeded and you want to inspect the pushed image → use **zot-registry**
- The failure is in application logic, not CI → use **debug-troubleshooting**
- You need to deploy after CI passes → use **gitops-deploy**

## Steps

### 1. Check Recent Runs
```bash
gh run list --repo keiretsu-labs/kubernetes-manifests --limit 10
```

### 2. Inspect a Failed Run
```bash
gh run view <run-id> --repo keiretsu-labs/kubernetes-manifests
gh run view <run-id> --repo keiretsu-labs/kubernetes-manifests --log-failed
```

### 3. Common Failures

**Build failure (Dockerfile.openclaw):**
- Tool download URL changed or version doesn't exist
- QEMU emulation issue on arm64 build
- Base image `ghcr.io/openclaw/openclaw:2026.2.9` unavailable
- **Fix:** Update the URL/version in Dockerfile, or wait for upstream fix

**Push failure (skopeo):**
- Zot registry unreachable from GHA runner
- Bad credentials (`ZOT_USERNAME`/`ZOT_PASSWORD` secrets)
- `skopeo copy` format wrong — must be `docker-archive:<file>.tar`
- **Fix:** Check secrets, verify registry connectivity, check format

**Manifest failure (crane):**
- `crane index append` fails if per-arch images weren't pushed
- Tag format mismatch
- **Fix:** Verify both arch images exist before manifest creation

**Workspace build failure:**
- Dockerfile.workspace syntax error
- Missing files referenced in COPY
- **Fix:** Check the COPY paths match actual workspace file structure

**No CI triggered:**
- Commit didn't change files matching the workflow's `paths` filter
- Workflow is disabled or has syntax error
- **Fix:** Check `.github/workflows/*.yaml` path filters

### 4. Fix Pattern
```bash
# Clone, fix the issue
git clone https://github.com/keiretsu-labs/kubernetes-manifests.git /tmp/oc-fix
cd /tmp/oc-fix
# edit the file...
git add <file> && git commit -m "fix: ..." && git push

# Watch the new run
gh run list --repo keiretsu-labs/kubernetes-manifests --limit 1
gh run watch <new-run-id> --repo keiretsu-labs/kubernetes-manifests
```

## Diagnosis Template

```markdown
## CI Failure Report

**Run:** #<run-id>
**Workflow:** <workflow name>
**Trigger:** <push/PR/manual>
**Failed step:** <step name>

### Error
<exact error message from logs>

### Root Cause
<why it failed>

### Fix
<what needs to change>

### Prevention
<how to avoid this in the future>
```

## Edge Cases

- **Flaky failures:** QEMU emulation occasionally fails on arm64 — re-run the workflow before investigating
- **Secrets expired:** If ZOT credentials rotated, all push steps will fail — check secret freshness
- **Concurrent runs:** Two pushes close together can race on manifest creation — check both runs

## Security Notes

- CI workflows run with GitHub secrets (ZOT_USERNAME, ZOT_PASSWORD) — review workflow changes carefully for exfiltration
- Never log secret values when debugging — use masked outputs
- Workflow file changes (.github/workflows/*) deserve extra scrutiny in code review
