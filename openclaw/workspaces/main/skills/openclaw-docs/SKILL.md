---
name: OpenClaw Docs Lookup
description: >
  Look up OpenClaw documentation via web_fetch — config reference, agent
  runtime, skills, cron, providers, sessions.

  Use when: You need to verify a config key, understand an OpenClaw feature,
  or look up documentation before making changes. Always use before changing
  config keys you're unsure about or when encountering unknown features.

  Don't use when: The answer is already in your workspace files (AGENTS.md,
  TOOLS.md, MEMORY.md, or skill files). Don't use for Kubernetes docs
  (use kubectl --help or official k8s docs). Don't use for general web
  searches (use web_search instead).

  Outputs: Documentation content fetched via web_fetch. No persistent
  artifacts — the information is used in-context.
requires: []
---

# OpenClaw Docs Lookup

## Routing

### Use This Skill When
- Changing config keys and need to verify they exist
- Adding new providers or models and need the format
- Setting up cron jobs, hooks, or automation
- Debugging startup failures that might be config-related
- Encountering an OpenClaw feature you haven't seen before
- Someone asks about OpenClaw capabilities or configuration

### Don't Use This Skill When
- The answer is in AGENTS.md, TOOLS.md, or MEMORY.md → check workspace files first
- You need Kubernetes/kubectl documentation → use `kubectl <cmd> --help`
- You need general information → use `web_search`
- You already know the config key and format → just make the change
- You're debugging pod/Flux/CI issues → use the appropriate troubleshooting skill

You have access to the full OpenClaw documentation at `docs.openclaw.ai`. Use `web_fetch` to look up answers before guessing.

## How to Look Things Up

### 1. Master Index
Fetch `https://docs.openclaw.ai/llms.txt` to get the full doc index with every page URL. Use this when you're not sure which page has the answer.

### 2. Direct Page Access
If you know the topic, go straight to the page:

| Topic | URL |
|-------|-----|
| **Config reference** | `https://docs.openclaw.ai/gateway/configuration` |
| **Agent runtime** | `https://docs.openclaw.ai/concepts/agent-runtime` |
| **Multi-agent routing** | `https://docs.openclaw.ai/concepts/multi-agent` |
| **Memory system** | `https://docs.openclaw.ai/concepts/memory` |
| **Sessions** | `https://docs.openclaw.ai/concepts/sessions` |
| **Model failover** | `https://docs.openclaw.ai/concepts/model-failover` |
| **Skills** | `https://docs.openclaw.ai/tools/skills` |
| **Sub-agents** | `https://docs.openclaw.ai/tools/agents` |
| **Exec / shell tools** | `https://docs.openclaw.ai/tools/exec` |
| **Web tools** | `https://docs.openclaw.ai/tools/web` |
| **Cron jobs** | `https://docs.openclaw.ai/automation/cron` |
| **Hooks** | `https://docs.openclaw.ai/automation/hooks` |
| **Heartbeat** | `https://docs.openclaw.ai/gateway/heartbeat` |
| **Health checks** | `https://docs.openclaw.ai/gateway/health` |
| **Sandboxing** | `https://docs.openclaw.ai/gateway/sandbox` |
| **Discord channel** | `https://docs.openclaw.ai/channels/discord` |
| **Environment vars** | `https://docs.openclaw.ai/help/env` |
| **Troubleshooting** | `https://docs.openclaw.ai/help/debugging` |
| **FAQ** | `https://docs.openclaw.ai/help/faq` |
| **Docker install** | `https://docs.openclaw.ai/installation/docker` |
| **Model providers** | `https://docs.openclaw.ai/providers/overview` |
| **Custom providers** | `https://docs.openclaw.ai/providers/custom` |
| **CLI reference** | `https://docs.openclaw.ai/cli/overview` |
| **ClawHub (skills marketplace)** | `https://docs.openclaw.ai/tools/clawhub` |

### 3. Config Schema Quick Reference

OpenClaw config (`clawdbot.json`) top-level keys:
```
gateway        — port, auth, controlUi
models         — providers, mode
agents         — defaults, list
session        — scope, idleMinutes
tools          — profile, web, exec
skills         — entries, load
channels       — discord, telegram, whatsapp, etc.
logging        — level, consoleStyle
commands       — parsing settings
messages       — prefixes, reactions
```

Agent-level keys (under `agents.defaults` or per-agent in `agents.list`):
```
model          — primary, thinking, failover
workspace      — path to workspace dir
identity       — name, emoji
heartbeat      — every, model, target, activeHours
subagents      — allowAgents, model, maxConcurrent
compaction     — memoryFlush settings
memorySearch   — enabled, sources, experimental
timeoutSeconds — max turn duration
maxConcurrent  — concurrent session limit
```

**Common mistake:** putting agent-level keys at root level. They MUST go under `agents.defaults` or a specific agent in `agents.list`.

### 4. ClawHub — Community Skills

Search and install community skills:
```bash
clawhub search "kubernetes"
clawhub install <skill-slug>
clawhub update --all
```

Notable ops skills: `kubernetes`, `docker-essentials`, `git-essentials`, `gitflow`
