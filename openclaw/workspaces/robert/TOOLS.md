# Tools

All CLI tools at `/usr/local/bin/`. Authenticated as `rajsinghtechbot` via GITHUB_TOKEN.

## Session Tools (Built-in)

These are OpenClaw built-in tools invoked as tool calls, NOT bash commands.

### sessions_list

List sessions with optional filtering.

```json
{
  "tool": "sessions_list",
  "params": {
    "activeMinutes": 1440,
    "limit": 100,
    "messageLimit": 5
  }
}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `kinds` | `string[]` | Filter by type: `"main"`, `"group"`, `"cron"`, `"hook"`, `"node"`, `"other"` |
| `limit` | `number` | Max rows returned |
| `activeMinutes` | `number` | Only sessions updated within N minutes (1440 = 24 hours) |
| `messageLimit` | `number` | Include last N messages per session (0 = none) |

### sessions_history

Fetch full transcript for a single session.

```json
{
  "tool": "sessions_history",
  "params": {
    "sessionKey": "<session-key>",
    "limit": 200,
    "includeTools": true
  }
}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sessionKey` | `string` | **Required.** Session key or session ID |
| `limit` | `number` | Max messages to return |
| `includeTools` | `boolean` | Include tool call results (default: false) |

### sessions_send

Send a message to another session (fire-and-forget).

```json
{
  "tool": "sessions_send",
  "params": {
    "sessionKey": "<session-key>",
    "message": "text",
    "timeoutSeconds": 0
  }
}
```

## gh

```bash
# Check for existing open PRs (deduplicate before creating new ones)
gh pr list --repo rajsinghtech/openclaw-workspace --author rajsinghtechbot --state open

# Clone
gh repo clone rajsinghtech/openclaw-workspace -- /tmp/robert-review

# Create PR
gh pr create --title "<type>: <description>" --body "## Findings\n..."

# Check CI status on your PRs
gh run list --repo rajsinghtech/openclaw-workspace --limit 5
```

## git

```bash
# Clone fresh every run
git clone https://github.com/rajsinghtech/openclaw-workspace.git /tmp/robert-review
cd /tmp/robert-review

# Branch, commit, push
git checkout -b robert/<topic>-$(date +%Y-%m-%d)
git add <files>
git commit -m "<type>: <description>"
git push origin robert/<topic>-$(date +%Y-%m-%d)
```

## Validation

```bash
# JSON
jq . <file.json> > /dev/null

# YAML
yq . <file.yaml> > /dev/null

# Kustomize render
kustomize build kustomization/
```

## Cluster Inspection

For cross-referencing workspace docs against live state.

```bash
# Current pod state
kubectl get pods -n openclaw -o wide

# Container names (compare against AGENTS.md)
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq '.items[0].spec.containers[].name'

# Current config (compare against openclaw.json in repo)
kubectl exec deployment/openclaw -c openclaw -n openclaw -- \
  cat /home/node/.openclaw/clawdbot.json | jq .

# Flux status
flux get kustomization -A | grep openclaw
```

## web_fetch

For looking up OpenClaw docs when verifying config keys or features.

```bash
# Doc index
web_fetch https://docs.openclaw.ai/llms.txt

# Specific pages
web_fetch https://docs.openclaw.ai/gateway/configuration
web_fetch https://docs.openclaw.ai/automation/cron
```
