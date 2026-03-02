# Bootstrap

This document describes the OpenClaw agent bootstrap process and workspace initialization.

## Workspace Files

| File | Purpose | Loads Every Session |
|------|---------|---------------------|
| `SOUL.md` | Persona and principles | Yes |
| `IDENTITY.md` | Quick reference card (name, role, vibe) | Yes |
| `USER.md` | Raj's profile and preferences | Yes |
| `AGENTS.md` | Operating instructions, session startup, skill routing | Yes |
| `TOOLS.md` | CLI tool reference and shortcuts | On demand |
| `MEMORY.md` | Curated operational knowledge | Direct sessions only |
| `HEARTBEAT.md` | 30-minute health check checklist | On heartbeat |
| `BRAIN.md` | Live working state — open loops, active watches | Yes |
| `PLAYBOOK.md` | Decision frameworks | On demand |
| `VOICE.md` | Communication format guide | On demand |
| `CLUSTERS.md` | Multi-cluster profiles | On demand |
| `EVENTS.md` | Event-driven alerting | On demand |
| `memory/` | Daily session logs (YYYY-MM-DD.md) | Today + yesterday |
| `shared-context/` | Cross-session knowledge | Direct sessions only |
| `skills/` | 22 specialized skill guides | On demand |

## Session Startup Routine

Defined in AGENTS.md "Every Session" section:

1. Read SOUL.md — who you are
2. Read USER.md — who you're helping
3. Read IDENTITY.md — quick reference
4. Read memory/ (today + yesterday) — recent context
5. If direct session: read MEMORY.md + shared-context/FEEDBACK-LOG.md
6. Check BRAIN.md — open loops and active watches

## Bootstrap Process

1. **Init Container** (`init-workspace`) — Syncs workspace files from OCI ImageVolume to PVC, preserving existing changes
2. **Config Injection** — Copies openclaw.json and cron-jobs.json from ConfigMap to PVC
3. **Extension Install** (`init-extensions`) — Installs MCP plugin dependencies
4. **Session Start** — Agent receives context + system prompt, follows startup routine

## Skills

Skills are stored in `workspaces/main/skills/` and loaded when relevant to the current task. See AGENTS.md for the full routing table.

## Configuration

- Workspace is managed via GitOps (Flux watches the repo)
- Changes pushed to `main` branch trigger CI builds
- Images pushed to `oci.killinit.cc` registry via skopeo
- Pod restarts pull fresh `:latest` images
- **Both running workspace AND repo must be updated** for changes to persist (see AGENTS.md "Self-Modification")
