# Claude Code notes (orchestrator)

@AGENTS.md

Everything about the repo — layout, add-app checklist, gotchas, verify
contract, cluster access — lives in `AGENTS.md` above. This file only holds
what is specific to Claude Code acting as the orchestrator.

## Development model

Claude Code orchestrates; pi build agents (`aperture/deepseek-v4-flash`) do
the implementation (manifests, Flux Kustomizations, HTTPRoutes). Claude plans,
reviews diffs, verifies with `tools/check.sh`, and commits.

### Calling the build agent

`tools/agent/pi-task.sh` drives `pi` non-interactively against the
aperture/deepseek-v4-flash backend: portable watchdog, auto-retry on the
backend's transient 503s, and it prints the saved session path for transcript
mining.

```bash
tools/agent/pi-task.sh "phase-title" "<self-contained prompt>" [deadline_secs=1800]
tools/agent/pi-task.sh --continue "fix ..." [deadline_secs]   # continue last session
```

- Run with Bash `run_in_background: true`; final assistant text lands on stdout.
- Exit 124 = watchdog timeout; on any failure it prints the stderr tail.
- Override model via `PI_MODEL` / `PI_PROVIDER`. The `aperture` provider is
  defined in `~/.pi/agent/models.json` (openai-completions, `http://aperture/v1`).

### Prompting build agents

Self-contained prompts: goal, exact file paths, acceptance criteria
(`tools/check.sh`). One app per run, few files per phase. Point add-app runs at
`docs/reference/app-template.md` (the copy-paste skeleton). If a run stalls or
emits broken YAML, `--continue` with the errors. Full pattern log:
`docs/prompt-notes.md`.

### Recurring toolsmith pass

After every 3–5 changes, launch an agent to mine pi session logs for wasted
tool calls and improve `tools/` / `docs/`: instructions in `docs/toolsmith.md`.

```bash
tools/agent/pi-task.sh "toolsmith-$(date +%Y%m%d)" "Read docs/toolsmith.md and follow it."
```
