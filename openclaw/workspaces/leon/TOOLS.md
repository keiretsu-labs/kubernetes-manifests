# Tools

All tools at `/usr/local/bin/`. Authenticated as `rajsinghtechbot` via GITHUB_TOKEN.

## Code Analysis

```bash
# Clone repos for review
git clone https://github.com/rajsinghtech/<repo>.git /tmp/review

# Search code patterns
grep -r "pattern" /path/to/code

# File tree analysis
find /path/to/code -type f -name "*.go" | head -20
```

## gh

```bash
# Clone repos
gh repo clone rajsinghtech/openclaw-workspace -- /tmp/oc-audit

# Check CI status
gh run list --repo rajsinghtech/openclaw-workspace --limit 5
gh run view <id> --repo rajsinghtech/openclaw-workspace

# Create PRs (for non-trivial changes)
gh pr create --title "fix: ..." --body "..."

# Review PRs
gh pr view <number> --repo rajsinghtech/<repo>
gh pr diff <number> --repo rajsinghtech/<repo>
```

## git

```bash
git clone https://github.com/rajsinghtech/<repo>.git /tmp/review
git diff HEAD~1                     # Show recent changes
git log --oneline -20               # Recent commits
git blame <file>                    # Line history
```

## Validation

```bash
# JSON
jq . <file.json> > /dev/null

# YAML
yq . <file.yaml> > /dev/null

# Language-specific
python -m py_compile <file.py>      # Python syntax check
go build ./...                       # Go compilation
npm run lint                         # JavaScript/TypeScript linting
```

## External Tools

- `web_search` — Search for coding patterns, best practices, documentation
- `web_fetch` — Fetch documentation or code examples
- `read` — Read source files
- `image` — Analyze screenshots of code/errors (if needed)

## Leon-Specific Skills

Located in `/home/node/.openclaw/workspaces/leon/skills/`:

| Skill | Purpose |
|-------|---------|
| `code-review/` | Structured code review process |
| `debug-troubleshooting/` | Systematic debugging approaches |
| `architecture-design/` | System design patterns and decisions |
| `testing-strategies/` | Test coverage and strategy guidance |
