# OpenClaw Optimization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce token costs 40-60%, improve agent effectiveness, and cut complexity by merging Ribak into Leon.

**Architecture:** Config tuning in openclaw.json for context/bootstrap limits, merge Ribak agent into Leon, tighten workspace docs across all agents.

**Tech Stack:** JSON config, Markdown workspace files, Kubernetes manifests

---

### Task 1: Config Tuning — openclaw.json

**Files:**
- Modify: `kustomization/openclaw.json`

**Step 1: Add contextTokens and bootstrap limits to agent defaults**

Add `contextTokens: 80000` to the existing `compaction` block and add a new `bootstrap` block:

```json
"defaults": {
  ...
  "compaction": {
    "contextTokens": 80000,
    "memoryFlush": {
      "enabled": true,
      "softThresholdTokens": 4000
    }
  },
  "bootstrap": {
    "maxChars": 10000,
    "totalMaxChars": 75000
  },
  ...
}
```

**Step 2: Remove allowInsecureAuth from controlUi**

Change:
```json
"controlUi": {
  "enabled": true,
  "allowInsecureAuth": true
}
```
To:
```json
"controlUi": {
  "enabled": true
}
```

**Step 3: Bump Dyson heartbeat from 15m to 30m**

Change dyson agent's `"every": "15m"` to `"every": "30m"`.

**Step 4: Remove ribak from agents list and all allowAgents**

- Delete the entire ribak agent object from `agents.list`
- Remove `"ribak"` from main agent's `subagents.allowAgents`
- Remove `"ribak"` from leon agent's `subagents.allowAgents`

**Step 5: Verify JSON is valid**

Run: `jq . kustomization/openclaw.json > /dev/null`

---

### Task 2: Update cron-jobs.json — Robert to daily

**Files:**
- Modify: `kustomization/cron-jobs.json`

**Step 1: Change Robert cron from 12h to daily**

Change schedule from `"0 6,18 * * *"` to `"0 6 * * *"`.
Update payload message from "last 12 hours" to "last 24 hours".

---

### Task 3: Merge Ribak into Leon

**Files:**
- Create: `workspaces/leon/skills/openspec/SKILL.md` (copy from ribak)
- Modify: `workspaces/leon/skills/code-review/SKILL.md` (merge ribak's review format)
- Modify: `workspaces/leon/SOUL.md` (add ribak's static analysis capabilities)
- Modify: `workspaces/leon/AGENTS.md` (remove ribak references, update role)
- Delete: `workspaces/ribak/` (entire directory)

**Step 1: Copy openspec skill to Leon**

Copy `workspaces/ribak/skills/openspec/SKILL.md` to `workspaces/leon/skills/openspec/SKILL.md`.
Update references from "Ribak" to "Leon" and remove "hand off to Leon" language (Leon IS the agent now).

**Step 2: Merge Ribak's review format into Leon's code-review skill**

Add Ribak's detailed static analysis checklist (cyclomatic complexity, null pointer checks, style enforcement) to Leon's existing code-review skill. Leon's skill already has the PR review workflow — just add the granular analysis section.

**Step 3: Update Leon's SOUL.md**

Add to Leon's capabilities:
- OpenSpec workflow management (was Ribak's)
- Detailed static analysis (was Ribak's specialty)
Remove any references to spawning Ribak.

**Step 4: Update Leon's AGENTS.md**

Remove Ribak from the agents table. Remove ribak from subagents mention. Add note that Leon handles both broad architecture review AND detailed static analysis directly.

**Step 5: Delete workspaces/ribak/**

Remove the entire directory.

---

### Task 4: Update cross-workspace references

**Files:**
- Modify: `workspaces/main/SOUL.md` (remove Ribak delegation section)
- Modify: `workspaces/main/AGENTS.md` (remove Ribak from agents table)
- Modify: `workspaces/morty/AGENTS.md` (remove Ribak from agents table if present)
- Modify: `workspaces/dyson/AGENTS.md` (remove Ribak from agents table if present)
- Modify: `workspaces/robert/AGENTS.md` (remove Ribak from agents table, update workspace tree)
- Modify: `workspaces/robert/SOUL.md` (update "every 12 hours" to "every 24 hours")

---

### Task 5: Tighten workspace docs — security boundaries

**Files:**
- Modify: `workspaces/main/SOUL.md`
- Modify: `workspaces/morty/SOUL.md`
- Modify: `workspaces/dyson/SOUL.md`
- Modify: `workspaces/leon/SOUL.md`
- Modify: `workspaces/robert/SOUL.md`

Add to each agent's SOUL.md Boundaries section (adapted per agent):
- NEVER expose secrets, API keys, or tokens in Discord messages or PR descriptions
- NEVER run destructive commands (kubectl delete, DROP, rm -rf) without explicit user confirmation
- NEVER push directly to main — always branch and PR (already in some, normalize across all)

Tighten existing prose: convert verbose paragraphs to bullet lists where possible.

---

### Task 6: Audit and trim MEMORY.md files

**Files:**
- Review and trim: `workspaces/main/MEMORY.md`
- Review and trim: `workspaces/morty/MEMORY.md`
- Review and trim: `workspaces/dyson/MEMORY.md`
- Review and trim: `workspaces/leon/MEMORY.md`
- Review and trim: `workspaces/robert/MEMORY.md`

Remove stale entries, tighten remaining content, ensure no redundancy within each file.

---

### Task 7: Update Dyson heartbeat references

**Files:**
- Modify: `workspaces/dyson/HEARTBEAT.md` (if it references 15m interval)
- Modify: `workspaces/main/SOUL.md` (update "every 15 minutes" to "every 30 minutes")
- Modify: `workspaces/main/AGENTS.md` (update Dyson heartbeat description)

---

### Task 8: Verify and commit

Run validation:
```bash
jq . kustomization/openclaw.json > /dev/null
jq . kustomization/cron-jobs.json > /dev/null
```

Verify no broken references remain:
```bash
grep -r "ribak" workspaces/ kustomization/
grep -r "every 12" workspaces/
grep -r "every 15" workspaces/ (should only appear in historical context, not active config)
```
