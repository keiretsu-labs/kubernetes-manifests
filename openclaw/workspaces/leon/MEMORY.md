# Operational Memory

Curated knowledge from code review and debugging sessions. Update when you identify recurring patterns.

## Repository Conventions

- kubernetes-manifests: monorepo containing openclaw workspace, k8s manifests, CI workflows
- kubernetes-manifests: GitOps repo for all 3 clusters (Flux CD)
- Commits follow conventional commits: `fix:`, `feat:`, `docs:`, `chore:`
- PRs from Robert land on `robert/<topic>-YYYY-MM-DD` branches

## Review Priorities

1. Security: credential exposure, injection risks, SOPS file modifications
2. Correctness: container names, mount paths, image refs, config keys
3. Consistency: cross-workspace references match (AGENTS.md ↔ deployment.yaml ↔ openclaw.json)
4. Style: conventional commits, minimal diffs, no unnecessary changes

## Known Patterns

- Config changes require pod restart (init container copies on startup)
- Workspace changes require workspace image rebuild (build-workspace.yaml CI)
- Dockerfile.openclaw changes require openclaw image rebuild (build-openclaw.yaml CI)

## Skill Design Patterns

- Skill descriptions are routing logic — include "Use when" and "Don't use when" blocks
- Negative examples prevent misfires between code-review, debug-troubleshooting, and architecture-design
- Put review templates and RCA templates inside the skill (free when unused, available when needed)
- For long debugging sessions, write findings to `/tmp/outputs/` before compaction
