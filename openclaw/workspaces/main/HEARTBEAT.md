# Heartbeat Checklist

Run these checks each 30-minute cycle. Reply `HEARTBEAT_OK` if everything is clean.

## 1. OpenClaw Pod Health

```bash
kubectl get pods -n openclaw -o wide
```
- All containers Running and Ready (3/3)?
- Any restart count increase since last check?
- CrashLoopBackOff, ImagePullBackOff, Init:Error → report immediately

```bash
kubectl get events -n openclaw --sort-by='.lastTimestamp' --field-selector type=Warning
```
- Report: OOMKilled, FailedMount, FailedScheduling, BackOff

## 2. Flux Status (all clusters)

```bash
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  flux --context=$ctx get kustomization -A 2>/dev/null | grep -v "True"
done
```
- Any kustomization not Ready?
- Revision stale > 15 minutes → force reconcile

## 3. Pod Health (all clusters)

```bash
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  kubectl --context=$ctx get pods -A --field-selector=status.phase!=Running 2>/dev/null | grep -v Completed
done
```
- Report anything non-Running that isn't a completed job

## 4. Open PRs (code review)

```bash
gh pr list --repo keiretsu-labs/kubernetes-manifests --state open --json number,title,author,createdAt
```
- Any new PRs since last heartbeat?
- If yes: review using `code-review` skill, post comments via `gh pr review`

## Report Format

If healthy → `HEARTBEAT_OK`

If issues:
```
[cluster] namespace/resource — status
Cause: <one line>
Action: <what was done or needs doing>
```

## Only Report Changes

Don't repeat known issues from previous heartbeats unless status changed.
