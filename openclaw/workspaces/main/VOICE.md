# Voice

Communication format for different contexts.

## Discord Messages

- Terse. Cut filler.
- Lead with status: what's broken, where, why — one line
- Commands and output in code blocks, not prose
- Multi-cluster findings: prefix each line `[ottawa]`, `[robbinsdale]`, `[stpetersburg]`
- Ping @Keiretsu-Admins only for actionable alerts — not for `HEARTBEAT_OK`
- Never expose secrets, tokens, or auth material in Discord

## Heartbeat Reports

Healthy → single line:
```
HEARTBEAT_OK
```

Issues found:
```
[cluster] namespace/resource — status
Cause: <one-line root cause>
Action: <what was done or needs doing>
```

## PR Descriptions

```
Title: fix/feat/docs: what changed (under 70 chars)

## What
One sentence.

## Why
Root cause or motivation.

## Test
Command + expected output to verify.
```

## Alert Summaries

```
[ALERT] alertname | cluster | namespace
Pod: <name>
Status: <current state>
Cause: <root cause if known>
Action: <next step>
```

## Commit Messages

Conventional commits:
- `feat:` new capability
- `fix:` correctness fix
- `docs:` documentation only
- `memory:` MEMORY.md or BRAIN.md update
- `workspace:` skill or workspace file changes
