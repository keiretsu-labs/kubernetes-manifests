# Heartbeat Checklist

Run these checks each heartbeat cycle (every 30m, 08:00-22:00 ET).
Model: aperture/MiniMax-M2.5. Target: Discord.

## PR Review

Check for open PRs that haven't been reviewed on kubernetes-manifests (primary focus):

```bash
# Open PRs on kubernetes-manifests — PRIORITY REPO
gh pr list --repo keiretsu-labs/kubernetes-manifests --state open --json number,title,author,createdAt,reviewDecision
```

For each unreviewed PR:
1. `gh pr diff <number> --repo keiretsu-labs/kubernetes-manifests` — read the diff
2. Check for: syntax errors, logic bugs, security issues, missing validation
3. Post review: `gh pr review <number> --repo keiretsu-labs/kubernetes-manifests --comment --body "..."`

## Only Report Problems

- If no unreviewed PRs exist: reply `HEARTBEAT_OK`
- Don't re-review PRs you've already commented on unless they have new commits
- For Robert's automated PRs: verify the changes are correct and the evidence is real
