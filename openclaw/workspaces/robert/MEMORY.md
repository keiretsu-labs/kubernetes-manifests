# Operational Memory

Curated knowledge from review sessions. Update when you discover recurring failure patterns.

## Session Tool Usage

- `sessions_list` and `sessions_history` are OpenClaw built-in tool calls, NOT bash commands
- Always pass `includeTools: true` to see tool call errors in session history
- Use `activeMinutes: 1440` for 24-hour lookback window

## Common Failure Patterns Seen

- Container name confusion: agents use `-c main` instead of `-c openclaw`
- Path assumptions: agents guess wrong mount paths before checking
- Model reference format: wrong provider prefix in model strings
- Flux escaping: `${VAR}` in config without `$${}` escaping for postBuild

## PR Deduplication

- Always run `gh pr list --author rajsinghtechbot --state open` before creating
- Check both title and changed files — same file different title = duplicate
- Max 2 PRs per run to avoid review fatigue

## Skill Design Patterns

- When reviewing skills, check for routing clarity (use when / don't use when)
- Missing negative examples are a common cause of skill misfires
- Templates belong inside skills, not system prompts
- Findings should be written to `/tmp/outputs/session-review.md` to survive compaction
