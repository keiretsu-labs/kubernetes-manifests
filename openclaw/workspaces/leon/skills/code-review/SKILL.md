---
name: Code Review
description: >
  Structured PR review — security scan, correctness, consistency, style.
  Covers diff analysis, comment posting via gh, and priority-based finding reports.

  Use when: A PR needs review, someone asks for code feedback, or changes need
  security/correctness validation before merge. Also use for pre-commit review
  of your own changes.

  Don't use when: The issue is a runtime pod failure (use pod-troubleshooting),
  a Flux reconciliation error (use flux-debugging), or a CI build failure
  (use ci-diagnosis). Don't use for architecture-level design discussions
  (use architecture-design instead).

  Outputs: Review comment posted on the PR via `gh pr review`, or a structured
  findings report grouped by severity (Critical/High/Medium/Low).
requires: [gh, git]
---

# Code Review

## Routing

### Use This Skill When
- A PR is open and needs review before merge
- Someone asks "can you review this code/PR?"
- You're validating changes before committing them yourself
- Checking a diff for security issues, correctness, or style

### Don't Use This Skill When
- A pod is crashing or not starting → use **pod-troubleshooting**
- Flux can't reconcile a kustomization → use **flux-debugging**
- CI workflow failed → use **ci-diagnosis**
- You need to discuss component design or architecture → use **architecture-design**
- You need to write or run tests → use **testing-strategies**
- The "review" is actually debugging live behavior → use **debug-troubleshooting**

## Steps

### 1. Get the Diff

```bash
# PR diff
gh pr diff <number> --repo rajsinghtech/<repo>

# Or clone and diff locally
git clone https://github.com/rajsinghtech/<repo>.git /tmp/review
cd /tmp/review
git diff main...<branch>
```

### 2. Review Checklist

For each changed file, check:

**Correctness**
- Does the logic do what the PR description says?
- Edge cases handled? (nil/null, empty, overflow, concurrency)
- Error handling: are errors caught, logged, and propagated correctly?

**Security**
- No hardcoded secrets, tokens, or credentials
- Input validation on external data (user input, API responses)
- No SQL/command injection, XSS, path traversal
- SOPS files not modified or exposed
- No `${VAR}` patterns that leak secrets through Flux substitution

**Style & Maintainability**
- Follows existing codebase conventions
- No unnecessary complexity or premature abstraction
- Clear naming, reasonable function length
- Tests for new logic

**Infrastructure (for K8s/Flux changes)**
- YAML/JSON valid (`yq .` / `jq .`)
- Kustomize builds cleanly (`kustomize build`)
- `$${VAR}` escaping correct for Flux postBuild
- No unintended secret exposure
- Resource limits set
- Container name is `openclaw` (not `main`)

### 3. Report

Format findings by severity:
- **Critical** — Will break production or expose data
- **High** — Bug or security issue that should block merge
- **Medium** — Design concern or missing edge case
- **Low** — Style nit or minor improvement

### 4. Post Review

```bash
# Post review on PR
gh pr review <number> --repo rajsinghtech/<repo> --comment --body "## Review

### Critical
- ...

### High
- ...

### Approved / Changes Requested
..."
```

## Review Templates

### Standard PR Review

```markdown
## Code Review

**PR:** #<number> — <title>
**Reviewer:** Leon
**Verdict:** ✅ Approved / ⚠️ Changes Requested / 🚫 Blocked

### Summary
<1-2 sentence overview of what the PR does and whether it's correct>

### Findings

#### Critical
- None / <finding with file:line reference>

#### High
- None / <finding>

#### Medium
- None / <finding>

#### Low
- None / <finding>

### Security Checklist
- [ ] No hardcoded credentials
- [ ] No secret exposure through Flux substitution
- [ ] Input validation present where needed
- [ ] SOPS files unchanged or correctly re-encrypted

### Infrastructure Checklist (if applicable)
- [ ] `kustomize build` passes
- [ ] Container names correct (`openclaw`, not `main`)
- [ ] `$${VAR}` escaping correct
- [ ] Resource limits set
```

### Quick LGTM (for trivial changes)

```markdown
## Review: LGTM ✅

Checked: syntax valid, no security concerns, follows conventions.
```

## Detailed Static Analysis

For deeper reviews beyond the standard checklist:

**Cyclomatic Complexity** — Flag functions with high branching complexity. Suggest extraction or simplification when a single function has too many conditional paths.

**Null/Nil Safety** — Check for nil pointer dereferences and null access with specific `file:line` references. In Go, check error returns before using the value. In JS/TS, check optional chaining gaps.

**Style Guide Enforcement** — Verify adherence to the project's established conventions: naming, import ordering, error message formatting, comment style. Reference the existing codebase as the style guide when no explicit one exists.

**Documentation Accuracy** — Check that comments, docstrings, and README references match the actual behavior of the code. Stale docs are worse than no docs.

For complex reviews, write detailed findings to `/tmp/outputs/review-<pr-number>.md` so other agents can reference them.

## Edge Cases

- **Large PRs (>500 lines):** Review in logical chunks (config, manifests, code). Don't try to hold the entire diff in context at once.
- **SOPS file changes:** Never approve blindly. Verify with `sops -d` that only expected keys changed. Flag if you can't verify.
- **Dockerfile changes:** Check base image pinning, layer ordering, and that no secrets are baked into layers.
- **CI workflow changes:** Extra scrutiny — these run with elevated GitHub secrets. Check for exfiltration patterns.

## Artifact Handoff

`mkdir -p /tmp/outputs` then write detailed review findings to `/tmp/outputs/review-<pr-number>.md` when the review is complex or needs to be referenced later by other agents.
