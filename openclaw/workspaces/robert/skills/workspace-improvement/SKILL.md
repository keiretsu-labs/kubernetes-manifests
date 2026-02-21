---
name: Workspace Improvement
description: >
  Cross-reference workspace docs against live deployment — container names,
  volume mounts, model providers, agent list, skill directories. Includes
  PR creation workflow with validation and deduplication.

  Use when: You have findings from session-review that need to be fixed,
  workspace docs may be stale, or you need to verify workspace accuracy
  against the live cluster. Also use after a deployment change to ensure
  docs stay in sync.

  Don't use when: You haven't done a session review yet (do that first with
  session-review). Don't use for live debugging (use the appropriate
  troubleshooting skill). Don't use for changes to kubernetes-manifests
  repo (Dyson's pr-workflow handles that).

  Outputs: Pull request(s) on rajsinghtech/openclaw-workspace with validated
  fixes to workspace docs, skills, or config. Max 2 PRs per run.
requires: [gh, git, kubectl, jq, yq]
---

# Workspace Improvement

## Routing

### Use This Skill When
- You have session-review findings that need workspace fixes
- Verifying workspace docs match the live deployment
- Updating stale container names, model lists, or path references
- Adding missing skills identified from session patterns
- Periodic workspace accuracy audit

### Don't Use This Skill When
- You haven't reviewed sessions yet → use **session-review** first
- The fix is in kubernetes-manifests, not openclaw-workspace → use Dyson's **pr-workflow**
- Debugging a live issue → use the appropriate troubleshooting skill
- The change is config (openclaw.json), not docs → be careful — config changes affect runtime

## Cross-Reference Checks

Compare what workspace docs say against what's actually deployed.

### Container Names

```bash
# Live state
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq -r '.items[0].spec.containers[].name'

# Compare against docs
grep -r "container" workspaces/*/AGENTS.md workspaces/*/TOOLS.md | grep -i "name\|exec\|-c "
```

### Volume Mounts

```bash
# Live mounts
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq '.items[0].spec.containers[0].volumeMounts[] | {name, mountPath}'

# Compare against documented paths in workspace files
grep -rn "/home/node\|/opt/workspace\|/opt/config" workspaces/
```

### Model Providers

```bash
# Live config providers
kubectl exec deployment/openclaw -c openclaw -n openclaw -- \
  cat /home/node/.openclaw/clawdbot.json | jq '.models.providers | keys'

# Repo config providers
jq '.models.providers | keys' kustomization/openclaw.json

# Compare against what AGENTS.md documents
grep -A2 "Provider" workspaces/main/AGENTS.md
```

### Agent List

```bash
# Live agents
kubectl exec deployment/openclaw -c openclaw -n openclaw -- \
  cat /home/node/.openclaw/clawdbot.json | jq '.agents.list[].id'

# Repo agents
jq '.agents.list[].id' kustomization/openclaw.json
```

### Skills vs Skill Directories

```bash
# Skill directories that exist
ls workspaces/main/skills/ workspaces/morty/skills/ workspaces/robert/skills/

# Skills referenced in AGENTS.md
grep -n "skill" workspaces/*/AGENTS.md
```

## Staleness Detection

Check if workspace content references outdated values:

```bash
# Image tags in docs vs deployment
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq -r '.items[0].spec.containers[].image'
grep -rn "ghcr.io\|oci.killinit.cc" workspaces/

# Tailscale version
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq -r '.items[0].spec.containers[] | select(.name=="tailscale") | .image'
grep -n "tailscale" workspaces/*/AGENTS.md
```

## PR Creation Workflow

### 1. Check for Duplicates

```bash
gh pr list --repo rajsinghtech/openclaw-workspace --author rajsinghtechbot --state open
```

Skip if an open PR already addresses the same issue.

### 2. Clone and Branch

```bash
# Always clean up stale clones — leftover state causes confusion
rm -rf /tmp/robert-review
git clone https://github.com/rajsinghtech/openclaw-workspace.git /tmp/robert-review
cd /tmp/robert-review
git checkout -b robert/<topic>-$(date +%Y-%m-%d)
```

⚠️ **Always `rm -rf` before cloning.** Previous session clones will have wrong branches and stale state.

### 3. Make Changes

Edit only the files that need fixing. Prefer minimal, targeted changes.

### 4. Validate

```bash
# If you touched JSON
jq . kustomization/openclaw.json > /dev/null

# If you touched YAML
yq . <file.yaml> > /dev/null

# If you touched kustomization resources
kustomize build kustomization/ > /dev/null
```

### 5. Commit and PR

```bash
git add <specific-files>
git commit -m "<type>: <description>"
git push origin robert/<topic>-$(date +%Y-%m-%d)

gh pr create \
  --title "<type>: <description>" \
  --body "## Findings
<evidence>

## Changes
<what and why>

## Sessions Referenced
<session IDs>"
```

### Commit Types

- `fix:` — corrects incorrect information
- `docs:` — updates stale or missing documentation
- `feat:` — adds new skill or capability
- `chore:` — cleanup, formatting, no behavior change

## PR Body Template

```markdown
## Findings

<Evidence from session review or cross-reference check>

## Changes

| File | Change |
|------|--------|
| `workspaces/<agent>/AGENTS.md` | <what changed> |
| `workspaces/<agent>/skills/<skill>/SKILL.md` | <what changed> |

## Sessions Referenced

<Session IDs where issues were observed, or "cross-reference check" if from audit>

## Validation

- [ ] No JSON/YAML syntax errors introduced
- [ ] Changes are factually correct (verified against live state)
- [ ] No duplicate PR exists for these changes
```

## Rules

- **Max 2 PRs per run** — avoid review fatigue
- **Check for duplicates** — always `gh pr list` before creating
- **Minimal changes** — fix only what's broken, don't refactor unrelated content
- **Include evidence** — every change needs a reason (session ID or audit finding)

## Security Notes

- Don't include raw session content with secrets or credentials in PR bodies
- Don't modify SOPS files — escalate to user
- Be careful editing config files — syntax errors crash the agent
