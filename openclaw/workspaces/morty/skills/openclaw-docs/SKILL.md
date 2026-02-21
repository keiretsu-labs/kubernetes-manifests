---
name: OpenClaw Docs Lookup (Morty)
description: >
  Look up OpenClaw documentation via web_fetch for config validation and verification.
  Use when: You need to verify a config key, understand OpenClaw configuration options,
  or check documentation for Kubernetes-specific settings before making changes.
  Don't use when: The answer is already in CONFIG.md, AGENTS.md, TOOLS.md in your workspace.
dontUseWhen:
  - The answer is in your workspace CONFIG.md
  - You're checking Kuberntes-specific Flux escaping (use CONFIG.md)
  - General web search needs
outputs: Documentation content or config validation results
requires: [web_fetch]
---

# OpenClaw Docs Lookup for Morty

Augments the main `openclaw-docs` skill with Kubernetes/Flux-specific awareness.

## Routing

### Use This Skill When

- Verifying config keys that might be specific to your deployment
- Checking if a config option requires special handling in Kubernetes
- Looking up agent heartbeat configuration options
- Understanding `subagents.allowAgents` syntax
- Validating model provider configuration

### Don't Use This Skill When

- Checking Flux variable escaping (`$${VAR}`) → see `CONFIG.md`
- Cron job syntax → see `CONFIG.md`
- Subagent spawning patterns → see `AGENTS.md`
- Kubernetes/Flux deployment issues → use `flux-debugging` skill

## Key URLs

| Topic | URL |
|-------|-----|
| Config reference | https://docs.openclaw.ai/gateway/configuration |
| Agent runtime | https://docs.openclaw.ai/concepts/agent-runtime |
| Multi-agent | https://docs.openclaw.ai/concepts/multi-agent |
| Sessions | https://docs.openclaw.ai/concepts/sessions |
| Model failover | https://docs.openclaw.ai/concepts/model-failover |
| TTS | https://docs.openclaw.ai/tts |

## Kubernetes-Specific Notes

Some documentation assumes local OpenClaw deployment. Key differences in K8s:

1. **Env Var Escaping**: Docs show `${VAR}` — you must use `$${VAR}` in git
2. **Config Persistence**: Changes to ConfigMap require pod restart (init container limitation)
3. **Workspace Updates**: Dockerfile.workspace rebuilds required for workspace changes
4. **Secret Management**: Use SOPS + Flux, not plain env files

## Config Pattern Quick Reference

```json
// Agent definition
{
  "id": "morty",
  "identity": { "name": "Morty", "emoji": "🔧" },
  "workspace": "/home/node/.openclaw/workspaces/morty",
  "model": { "primary": "aperture/MiniMax-M2.5" },
  "subagents": {
    "model": "aperture/MiniMax-M2.5",
    "allowAgents": ["main"]
  }
}

// Heartbeat configuration
{
  "heartbeat": {
    "every": "30m",
    "model": "aperture/MiniMax-M2.5",
    "target": "discord",
    "activeHours": {
      "start": "08:00",
      "end": "23:00",
      "timezone": "America/New_York"
    }
  }
}

// Model provider example
{
  "models": {
    "mode": "merge",
    "providers": {
      "aperture": {
        "baseUrl": "http://aperture",
        "apiKey": "unused",
        "api": "anthropic-messages"
      }
    }
  }
}
```

## Common Config Mistakes

| Mistake | Correction |
|---------|------------|
| Wrong `api` type for provider | aperture uses `anthropic-messages` |
| Missing `subagents.allowAgents` | Add explicit allowlist |
| Wrong workspace path | Must be `/home/node/.openclaw/workspaces/<id>` |
| Omitted `model.primary` | Required for each agent |
