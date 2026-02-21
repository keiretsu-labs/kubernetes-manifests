---
name: Session Review
description: >
  Analyze agent sessions for tool failures, retry patterns, knowledge gaps,
  context limits, and config drift.

  Use when: Running periodic session reviews (cron), investigating agent
  reliability issues, looking for recurring failure patterns, or identifying
  workspace improvements from real usage. This is the primary skill for
  Robert's review cron job.

  Don't use when: You're making changes to fix issues (use
  workspace-improvement for that). Don't use for live debugging of a
  current issue (use the appropriate troubleshooting skill). Don't use
  for code review of PRs (use code-review).

  Outputs: Session analysis report with categorized findings (tool failures,
  retries, knowledge gaps, config drift), severity ratings, and proposed
  fixes. Written to /tmp/outputs/session-review.md for handoff.
requires: []
---

# Session Review

## Routing

### Use This Skill When
- Running a periodic session review (daily cron)
- Investigating why an agent struggled with a task
- Looking for recurring failure patterns across agents
- Identifying stale docs or missing skills from real usage
- Someone asks "what went wrong in recent sessions?"

### Don't Use This Skill When
- You already have findings and need to open PRs → use **workspace-improvement**
- An issue is happening right now and needs live debugging → route to the appropriate agent
- Reviewing a PR's code quality → use **code-review** (leon)
- Looking at cluster health, not agent sessions → use **cluster-health** (dyson)

## Gathering Sessions

Use the built-in `sessions_list` and `sessions_history` tools (OpenClaw tool calls, NOT bash commands).

⚠️ **These are NOT shell commands.** Do not run them with `exec`. They are OpenClaw built-in tools.

### List recent sessions

```json
{ "tool": "sessions_list", "params": { "activeMinutes": 1440, "limit": 100, "messageLimit": 5 } }
```

- `activeMinutes: 1440` = last 24 hours
- `messageLimit: 5` = include last 5 messages per session for quick triage
- Use `kinds` to filter: `["main", "group", "cron", "hook"]`

### Get full session transcript

```json
{ "tool": "sessions_history", "params": { "sessionKey": "<key>", "limit": 200, "includeTools": true } }
```

- Set `includeTools: true` to see tool call results (where errors appear)
- Increase `limit` for long sessions

### Agents to review

Check sessions for ALL agents: **main**, **morty**, **dyson**, **leon**, **robert**.

## Error Patterns to Detect

### Tool Call Failures

Look for non-zero exit codes or error strings in tool responses:
- `command not found` — tool not installed or wrong name
- `error: ...` / `Error: ...` — command-level failure
- `No such file or directory` — wrong path assumption
- `container "main" not found` — wrong container name (should be `openclaw`)
- `EBUSY` / `ENOENT` — filesystem issues
- HTTP 4xx/5xx in API responses

### Retry Patterns

Agent attempted the same action multiple times:
- Same command run 2+ times with slight variations
- Agent said "let me try again" or "that didn't work"
- Repeated `kubectl` commands with different flags/names

### Knowledge Gaps

Agent didn't know something it should have:
- Asked docs for info that's in workspace files
- Guessed a config key and got it wrong
- Used wrong provider/model reference format
- Assumed wrong path for a file or mount

### Context Limits

Session hit token limits:
- Compaction triggered mid-task
- Agent lost track of earlier findings after compaction
- Session timed out before completing

## Categorization

For each finding, record:

| Field | Value |
|-------|-------|
| Session ID | `<id>` |
| Agent | `main` / `morty` / `dyson` / `leon` / `robert` |
| Timestamp | When the error occurred |
| Category | `tool-failure` / `retry` / `knowledge-gap` / `stale-docs` / `missing-skill` / `config-drift` |
| Severity | `breaking` / `misleading` / `enhancement` |
| Evidence | The actual error or exchange from the session |
| Fix | What workspace change would prevent this |

## Severity Guide

- **Breaking**: Incorrect info that directly causes tool failures (wrong container name, wrong path, bad command)
- **Misleading**: Stale or incomplete info that wastes agent time (outdated model list, missing skill reference)
- **Enhancement**: Patterns that could be encoded as skills or better docs but aren't causing failures

## Output Template

`mkdir -p /tmp/outputs` then write findings to `/tmp/outputs/session-review.md`:

```markdown
# Session Review Report

**Period:** <start> to <end>
**Sessions analyzed:** <N>
- main: <W> sessions
- morty: <X> sessions
- dyson: <Y> sessions
- leon: <Z> sessions
- robert: <R> sessions

## Findings

### Breaking
1. [tool-failure] <description> (sessions: <ids>)
   - Evidence: <error message>
   - Fix: <workspace change>

### Misleading
1. [stale-docs] <description> (sessions: <ids>)
   - Evidence: <what was wrong>
   - Fix: <doc update needed>

### Enhancements
1. [missing-skill] <description>
   - Evidence: <pattern seen>
   - Suggestion: <new skill or doc addition>

## Proposed PRs
1. fix: <description of change>
2. docs: <description of doc update>
```

## Compaction Notes

Session review can be long. To survive compaction:
- `mkdir -p /tmp/outputs` before writing any artifacts
- Write findings to `/tmp/outputs/session-review.md` as you go
- Process one agent at a time, writing findings before moving to the next
- Keep a running tally of sessions analyzed and findings count

## Security Notes

- Session transcripts may contain sensitive information — don't include raw secrets or credentials in reports
- Tool call outputs may include kubectl responses with resource details — sanitize before sharing
