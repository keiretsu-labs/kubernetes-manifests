# Claude Code notes (orchestrator)

@AGENTS.md

Everything about the repo — layout, add-app checklist, gotchas, verify
contract, cluster access — lives in `AGENTS.md` above. This file only holds
what is specific to Claude Code acting as the orchestrator.

## Development model

Claude Code orchestrates; opencode agents (`aperture/deepseek-v4-flash`) do
the implementation (manifests, Flux Kustomizations, HTTPRoutes). Claude plans,
reviews diffs, verifies with `tools/check.sh`, and commits.

### Calling opencode — use the server harness, NOT `opencode run`

`opencode run` is synchronous with no timeout; a stalled model blocks forever.
`tools/agent/opencode-task.sh` drives the persistent server HTTP API instead
(async prompt admission, allow-all permissions, watchdog deadline, result
harvesting):

```bash
tools/agent/opencode-task.sh "phase-title" "<self-contained prompt>" [deadline_secs=2400]
tools/agent/opencode-task.sh --continue <sessionID> "fix ..." [deadline_secs]
```

- Run with Bash `run_in_background: true`; final message lands on stdout.
- Exit 3 = watchdog abort (prints sessionID — inspect partial work, then
  `--continue`).
- Server auto-starts on 127.0.0.1:4096. Override model with
  OPENCODE_PROVIDER/OPENCODE_MODEL.
- Sessions: `opencode session list`, `opencode export <id>`.

### Prompting build agents

Self-contained prompts: goal, exact file paths, acceptance criteria
(`tools/check.sh`). One app per run, few files per phase. If a run stalls or
emits broken YAML, `--continue` the session with the errors. Full pattern log:
`docs/prompt-notes.md`.

### Recurring toolsmith pass

After every 3–5 changes, launch an agent to mine session logs for token
sinks and improve `tools/`: instructions in `docs/toolsmith.md`.

```bash
tools/agent/opencode-task.sh "toolsmith-$(date +%Y%m%d)" "Read docs/toolsmith.md and follow it."
```
