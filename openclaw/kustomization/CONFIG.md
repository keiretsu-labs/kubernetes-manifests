# OpenClaw Kubernetes Configuration Guide

This document covers OpenClaw configuration specifics for Kubernetes/Flux deployments.

## Environment Variable Substitution

When using Flux CD to deploy OpenClaw, environment variable substitution in `openclaw.json` requires special escaping.

### The Problem

Flux uses `${VAR}` syntax for variable substitution. OpenClaw also uses `${VAR}` for env var substitution in config. This creates a conflict.

### The Solution

Escape literal `${VAR}` as `$${VAR}` in the repository. At runtime, OpenClaw sees `${VAR}` and performs substitution.

```json
// In the repository (escaped for Flux):
{
  "models": {
    "providers": {
      "nvidia": {
        "apiKey": "$${NVIDIA_API_KEY}"
      }
    }
  }
}

// At runtime (after Flux applies, OpenClaw sees):
{
  "models": {
    "providers": {
      "nvidia": {
        "apiKey": "${NVIDIA_API_KEY}"
      }
    }
  }
}

// OpenClaw then substitutes from the actual environment variable
```

**All env vars in this repo use `$${VAR}` escaping.**

## Cron Jobs Configuration

Cron jobs are defined in `cron-jobs.json` and copied by the init container to `/home/node/.openclaw/cron/jobs.json`.

### Structure

```json
{
  "version": 1,
  "jobs": [
    {
      "id": "unique-job-id",
      "name": "Human-readable name",
      "enabled": true,
      "schedule": {
        "kind": "cron",
        "expr": "0 6,18 * * *",
        "tz": "America/New_York"
      },
      "agentId": "robert",
      "sessionTarget": "isolated",
      "wakeMode": "now",
      "payload": {
        "kind": "agentTurn",
        "message": "Your prompt here"
      }
    }
  ]
}
```

### Fields

| Field | Description |
|-------|-------------|
| `id` | Unique identifier for the job |
| `name` | Human-readable name (logs, UI) |
| `enabled` | Whether the job runs |
| `schedule.kind` | `"cron"` or `"interval"` |
| `schedule.expr` | Cron expression (when kind=cron) |
| `schedule.tz` | Timezone for cron expression |
| `agentId` | Which agent runs the job |
| `sessionTarget` | `"isolated"` or `"main"` |
| `wakeMode` | `"now"` or `"next-heartbeat"` |
| `payload.kind` | Always `"agentTurn"` |
| `payload.message` | The prompt sent to the agent |

### Init Container Behavior

The `init-workspace` container:
1. Copies `cron-jobs.json` → `/home/node/.openclaw/cron/jobs.json`
2. Copies `openclaw.json` → `/home/node/.openclaw/clawdbot.json`
3. Only runs on pod startup (changes require restart)

## Config Hot Reload

OpenClaw supports hot reload of config changes, but the init-container-copied files require pod restart to update because:

1. ConfigMap changes are mounted into the pod
2. But init containers only run at startup
3. The PVC-backed `/home/node/.openclaw/` persists across restarts

To apply config changes:
```bash
# Force restart
deployment/openclaw -n openclaw
```

## Heartbeat Configuration

Agents can run periodic heartbeats for autonomous tasks.

```json
{
  "agents": {
    "list": [
      {
        "id": "dyson",
        "heartbeat": {
          "every": "15m",
          "model": "aperture/MiniMax-M2.5",
          "target": "discord",
          "activeHours": {
            "start": "06:00",
            "end": "23:59",
            "timezone": "America/New_York"
          }
        }
      }
    ]
  }
}
```

### Heartbeat Fields

| Field | Description | Default |
|-------|-------------|---------|
| `every` | Duration between runs (e.g., "15m", "2h") | "30m" |
| `model` | Model to use for heartbeat | agent's default |
| `target` | Channel to send results to | "last" |
| `activeHours.start` | Daily start time | - |
| `activeHours.end` | Daily end time | - |
| `activeHours.timezone` | Timezone for hours | "America/New_York" |

## Subagent Configuration

Agents can spawn sub-agents with controlled permissions.

```json
{
  "subagents": {
    "allowAgents": ["morty", "dyson"],
    "model": "aperture/MiniMax-M2.5",
    "maxConcurrent": 16
  }
}
```

### Wildcards

- `["*"]` - Allow spawning any agent
- `["main"]` - Only certain agents
- `[]` or omitted - No subagents allowed

## Model Provider Merge Mode

When adding custom providers to the built-in catalog:

```json
{
  "models": {
    "mode": "merge",
    "providers": {
      "custom": {
        "baseUrl": "http://...",
        "apiKey": "$${CUSTOM_API_KEY}",
        "api": "openai-completions"
      }
    }
  }
}
```

- `mode: "merge"` - Adds your providers to the built-in catalog
- `mode: "replace"` - Replaces entirely (rarely used)

## Validation

Before committing changes:

```bash
# Validate JSON
jq . kustomization/openclaw.json > /dev/null
jq . kustomization/cron-jobs.json > /dev/null

# Validate YAML
yq . kustomization/deployment.yaml > /dev/null
yq . kustomization/kustomization.yaml > /dev/null

# Preview kustomize build
kustomize build kustomization/
```
