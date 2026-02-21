# OpenClaw Optimization Design

Date: 2026-02-19
Approach: Config Tuning + Workspace Trim (Approach 2)

## Goals

- Reduce token consumption 40-60% via context/bootstrap limits
- Improve agent effectiveness with tighter, actionable instructions
- Cut complexity by merging Ribak into Leon
- Add security boundaries to all agents
- Reduce heartbeat/cron costs

## Changes

### 1. Config Tuning (openclaw.json)

**Compaction defaults:**
- Add `contextTokens: 80000` — caps context before compaction (currently unbounded)
- Keep existing `memoryFlush` settings

**Bootstrap limits:**
- Add `bootstrap.maxChars: 10000` (default 20000)
- Add `bootstrap.totalMaxChars: 75000` (default 150000)
- Reduces workspace content loaded at session start

**Control UI:**
- Remove `allowInsecureAuth: true` — flagged as critical security issue

**Heartbeat:**
- Dyson: 15m → 30m (halves daily API calls ~72 → ~36)
- Main: keep at 30m

**Cron:**
- Robert: 12h → 24h (daily at 06:00 only)

**Not changing:**
- Discord config (groupPolicy, requireMention, dmPolicy) — user preference
- Tool profiles — keeping `full` for all agents
- Model configuration — keeping aperture/MiniMax-M2.5 for all

### 2. Merge Ribak into Leon

Ribak is a thin code-review sub-agent spawned by Leon. Leon already has code-review capabilities. Ribak's unique additions (openspec review, detailed static analysis format) can be folded into Leon directly.

**Steps:**
1. Copy Ribak's `openspec` skill to Leon's workspace
2. Merge Ribak's review format/style into Leon's code-review skill
3. Remove `ribak` from `agents.list` in openclaw.json
4. Remove `ribak` from all `subagents.allowAgents` lists (main, leon)
5. Delete `workspaces/ribak/` directory
6. Update any AGENTS.md references to Ribak across other workspaces

### 3. Workspace Content Trim

**All agent SOUL.md / AGENTS.md files:**
- Convert prose to bullet lists (more token-efficient)
- Remove verbose preambles and filler
- Remove content redundant with skills
- Add explicit security boundaries:
  - NEVER expose secrets/API keys in Discord messages
  - NEVER run destructive kubectl commands without confirmation
  - NEVER push to main branch
  - NEVER modify SOPS-encrypted files directly

**MEMORY.md audit:**
- Remove stale entries referencing resolved issues or old versions
- Tighten remaining entries for conciseness

**Skills:**
- Leave `openclaw-docs` duplication as-is (workspace-scoped, correct pattern)
- Audit each agent's skills for unused ones

## Expected Impact

| Metric | Before | After |
|--------|--------|-------|
| Context per session | Unbounded (200k+) | 80k cap |
| Bootstrap chars | 20k/150k | 10k/75k |
| Dyson heartbeats/day | ~72 | ~36 |
| Robert cron runs/day | 2 | 1 |
| Agent count | 6 | 5 (Ribak merged) |
| Token savings | baseline | 40-60% estimated |

## Out of Scope

- Model tiering (different models per agent)
- Merging Morty into main
- Dynamic skill loading
- Agent-specific sandbox modes
- Per-agent tool profile restrictions
