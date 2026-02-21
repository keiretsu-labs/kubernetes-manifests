---
name: Config Audit
description: >
  Validate openclaw.json and related config files — JSON syntax, model
  references, env var escaping, agent configuration, and known bad patterns.

  Use when: Config was recently edited, a new provider or agent was added,
  the pod crashes on startup with config errors, or you want to verify
  config correctness before deploying.

  Don't use when: The config is fine and a pod is crashing for other reasons
  (use pod-troubleshooting). Don't use for kustomize/manifest validation
  (use manifest-lint). Don't use for Flux-specific issues (use
  flux-debugging). Don't use for runtime behavior bugs (use
  debug-troubleshooting).

  Outputs: List of config issues found (if any), categorized by severity,
  with specific line references and fix suggestions.
requires: [jq, yq]
---

# Config Audit

## Routing

### Use This Skill When
- openclaw.json was recently edited and needs validation
- Pod is crashing on startup and you suspect bad config
- A new model provider or agent was added
- Before deploying config changes (pre-flight check)
- Periodic config hygiene audit
- Someone asks "is the config valid?"

### Don't Use This Skill When
- Pod crashes are not config-related → use **pod-troubleshooting**
- Validating kustomize manifests (deployment.yaml, etc.) → use **manifest-lint**
- Flux reconciliation failing → use **flux-debugging**
- Runtime behavior is wrong but config is valid → use **debug-troubleshooting**
- Inspecting live config in the running pod → just `kubectl exec` and `jq`

## Steps

```bash
# Clone fresh
git clone https://github.com/rajsinghtech/openclaw-workspace.git /tmp/oc-audit
cd /tmp/oc-audit
```

### 1. JSON Syntax
```bash
jq . kustomization/openclaw.json > /dev/null
```
If this fails, the JSON is malformed — fix syntax before any other checks.

### 2. Model References
Every `"primary"` value must match `<provider>/<model-id>` where the provider exists in `models.providers`:
```bash
# List configured providers
jq -r '.models.providers | keys[]' kustomization/openclaw.json

# List all model refs in agents
jq -r '.. | .primary? // empty' kustomization/openclaw.json
```
Verify each model ref's provider prefix exists in the providers list.

### 3. Env Var Escaping
Any `${VAR}` that OpenClaw should resolve at runtime must be `$${VAR}` in the repo (Flux postBuild eats single `${}`):
```bash
# Find all ${} refs — these will be substituted by Flux (possibly wrong)
grep -n '${' kustomization/openclaw.json | grep -v '$${'
# ^ should be empty. If not, those vars get Flux-substituted.

# Find all $${} refs — these survive Flux and become ${} for OpenClaw
grep -n '$${' kustomization/openclaw.json
```

### 4. Agent Config
```bash
# Check all agents have identity
jq '.agents.list[] | {id, identity}' kustomization/openclaw.json

# Check workspace paths exist in the OCI image
jq -r '.agents.defaults.workspace, (.agents.list[] | .workspace // empty)' kustomization/openclaw.json
```

### 5. Known Bad Patterns
- Top-level `compaction` or `memorySearch` keys → must be under `agents.defaults`
- `"primary": "provider/model"` where provider has slashes (OpenRouter) → needs full prefix
- `apiKey` without `$${}` escaping for Flux-substituted secrets
- `web.search.enabled: true` without a provider or apiKey
- Duplicate agent IDs in `agents.list`
- Missing `identity.name` or `identity.emoji` for any agent

## Audit Report Template

```markdown
## Config Audit Report

**File:** kustomization/openclaw.json
**Date:** <date>

### Critical
- <issues that will crash the agent>

### Warning
- <issues that may cause unexpected behavior>

### Info
- <suggestions for improvement>

### Summary
<N> issues found: <X> critical, <Y> warning, <Z> info
```

## Edge Cases

- **Valid JSON but invalid OpenClaw config:** JSON parses fine but has wrong key names or structure — check docs if unsure about a key
- **Escaping looks wrong but works:** Some `${VAR}` patterns are intentionally Flux-substituted (like `${CLUSTER_DOMAIN}`) — check context
- **Multiple config files:** `cron-jobs.json` also needs validation — don't forget it
