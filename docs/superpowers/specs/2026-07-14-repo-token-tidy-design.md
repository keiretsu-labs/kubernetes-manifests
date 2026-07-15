# Repo tidy-up & token efficiency — design

2026-07-14. Approved scope: reduce per-session context cost for every agent
(Claude Code, opencode, codex, pi) and clean up repo debris.

## 1. AGENTS.md as spine

- New `AGENTS.md` (~200–250 lines), read natively by opencode/codex/pi and
  imported by CLAUDE.md. Single source of truth for:
  - GitOps/Flux model, base + overlay layout, reconcile chain (condensed)
  - Add-a-new-app checklist
  - Critical gotchas: envsubst `$` mangling, `${COMMON_DOMAIN}` CNAME
    requirement, gateway listener hostnames, SOPS, kubectl contexts
  - Verify contract: `tools/check.sh` sole acceptance gate; `tools/where.sh`
    before re-reading large files
  - Agent workflow: opencode server harness, prompting rules (from
    docs/prompt-notes.md)
- `CLAUDE.md` shrinks from ~1,030 lines to a thin wrapper: `@AGENTS.md`
  import + Claude-specific orchestration notes.
- Cut content: delete stale inventory/workflow-catalog/editor-config/tables
  sections; move tsdb, Talos, and Tailscale integration detail to
  `docs/reference/`.
- Fix contradiction: CLAUDE.md is git-tracked; stop claiming it's ignored.

## 2. MEMORY.md restructure

Auto-memory index (`~/.claude/projects/.../memory/MEMORY.md`) holds ~10KB of
inlined OpenClaw/cluster content. Move into individual memory files with
frontmatter; index becomes one-line pointers only.

## 3. Worktree/debris cleanup

- Remove `.claude/worktrees/garage-cdn` after checking for unmerged work.
- Report (not remove) external worktrees: km-garage-rpc, km-cdn-site,
  km-claude-dsv4.
- Leave `.opencode/node_modules` (gitignored, opencode runtime dep).

## 4. Commit uncommitted work

1. Agent tooling: `tools/`, `docs/toolsmith.md`, `docs/prompt-notes.md`,
   `docs/parity.md`, `opencode.json`.
2. AGENTS.md + slimmed CLAUDE.md + `docs/reference/` moves.
3. rustscale sidecar experiment (`ts-sidecar.yaml`) — separate commit,
   gated on `tools/check.sh`.

Commits as local user, pushed after each.
