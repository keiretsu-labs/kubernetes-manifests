# Bootstrap

This document describes the OpenClaw agent bootstrap process and workspace initialization.

## Workspace Files

The OpenClaw workspace is initialized with the following bootstrap files:

| File | Purpose |
|------|---------|
| `AGENTS.md` | Agent operating instructions, sub-agent patterns, GitOps pipeline |
| `SOUL.md` | Persona, tone, and self-modification patterns |
| `USER.md` | User profile and preferences |
| `IDENTITY.md` | Agent identity and capabilities |
| `TOOLS.md` | CLI tool reference and shortcuts |
| `MEMORY.md` | Operational knowledge from past sessions |
| `HEARTBEAT.md` | Time-based health check checklist |
| `EVENTS.md` | Event-driven alerting mechanisms |

## Bootstrap Process

1. **Init Container** - Copies workspace files from ImageVolume to emptyDir
2. **Workspace Injection** - Bootstrap files are injected into the agent's context
3. **Skill Loading** - Skills are loaded on-demand based on task matching
4. **Session Start** - Agent receives context + system prompt

## Skills

Skills are stored in `workspaces/main/skills/` and loaded when relevant to the current task:

- `cluster-context` - Pod architecture, volumes, networking
- `flux-debugging` - Flux CD reconciliation troubleshooting
- `pod-troubleshooting` - Container failure diagnosis
- `gitops-deploy` - End-to-end deployment workflow
- `zot-registry` - OCI registry operations
- `memory-management` - Context hygiene and compaction
- `openclaw-docs` - Documentation lookup

## Configuration

- Workspace is managed via GitOps (Flux)
- Changes pushed to `main` branch trigger CI builds
- Images pushed to `oci.killinit.cc` registry
- Pods auto-restart to pull fresh images
