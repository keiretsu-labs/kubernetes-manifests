---
name: Memory Management
description: >
  Context hygiene, memory flush before compaction, sub-agent lifecycle, and
  daily operations patterns.

  Use when: Context is growing large and you need to prepare for compaction,
  switching between unrelated tasks, or establishing a daily operations
  routine. Also use when spawning sub-agents for long tasks.

  Don't use when: Debugging a specific issue (use the appropriate
  troubleshooting skill). Don't use for deploying changes (use
  gitops-deploy). This is an internal operations pattern, not a diagnostic
  tool.

  Outputs: No external artifacts. This skill guides internal behavior —
  writing to workspace files, spawning sub-agents, and managing context.
requires: []
---

# Memory Management

## Routing

### Use This Skill When
- Context window is getting large and compaction is approaching
- Switching from one task to a completely different topic
- Starting a new session and need to reload context
- Spawning a sub-agent for a long-running task
- Need to persist important findings before they're compacted away

### Don't Use This Skill When
- Debugging a pod, Flux, or CI issue → use the specific skill
- Deploying changes → use **gitops-deploy**
- Reviewing sessions → use **session-review**
- This is about managing YOUR OWN context, not the user's data

## Context Hygiene

### Before Starting a New Task
Run `/compact` to clear stale context before switching topics. This prevents hallucination from prior task context bleeding into the new one.

### After Configuring Something
Commit important details to memory immediately. Verify by repeating the key facts back. Don't rely on session context surviving — compaction or restarts will lose it.

### When Context Seems Incomplete
Search session memory before asking the user to repeat themselves:
- Check recent conversation for relevant details
- Review workspace files that may contain the answer
- Only ask after confirming the info isn't available

## Sub-Agents for Long Tasks

Spawn sub-agents for tasks that may exceed session timeout (60 min idle):
- Scheduled/cron monitoring tasks
- Long-running build watches
- Periodic health checks

Sub-agents run independently and won't be killed by the parent session timing out.

```
Main agent → spawns sub-agent for monitoring
Main agent session can idle/timeout
Sub-agent continues running
```

## Memory Flush Before Compaction

When context is getting large and compaction is imminent, flush important state to persistent storage:
- Write key findings to workspace files (MEMORY.md, or task-specific files)
- Update any tracking documents
- Log decisions and their rationale

**Standard flush locations** (`mkdir -p /tmp/outputs` first):
- `/tmp/outputs/<task>.md` — temporary task artifacts
- `workspaces/<agent>/MEMORY.md` — persistent learned knowledge
- Workspace skill files — if you learned something about a skill's domain

This ensures nothing critical is lost when the context window compresses.

## Daily Operations Pattern

1. **Start of session:** Review workspace files for context, run health checks
2. **During work:** Commit decisions and findings to memory as you go
3. **Before idle:** Flush any uncommitted knowledge to workspace files
4. **On return:** Check workspace files and events since last active

## Memory Search

When looking for prior context:
1. Check workspace files first (persistent across restarts)
2. Search session memory for recent interactions
3. Check pod logs for operational history: `kubectl logs -c openclaw --tail=200`
4. Review Kubernetes events: `kubectl get events -n openclaw --sort-by='.lastTimestamp'`

## Compaction Design Principles

From OpenAI's guidance on long-running agents:
- **Use compaction as a default primitive**, not an emergency fallback
- **Write intermediate findings to disk** before they're compacted away
- **Design for continuity** — assume context will be compressed
- **Keep running tallies** in files, not just in context
