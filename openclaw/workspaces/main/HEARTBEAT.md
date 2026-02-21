# Heartbeat Checklist

Run these checks each heartbeat cycle. If everything is healthy, reply HEARTBEAT_OK.

## Pod Health
- Check `kubectl get pods -n openclaw -o wide` — are all containers Running and Ready (2/2)?
- If any container has restarted since last check, report the restart count and check logs
- If pod is in CrashLoopBackOff, ImagePullBackOff, or Init:Error — report immediately

## Flux Status
- Check `flux get kustomization -A | grep openclaw` — is it Ready with a recent revision?
- If reconciliation failed, report the error message

## Recent Events
- Check `kubectl get events -n openclaw --sort-by='.lastTimestamp' --field-selector type=Warning` for warnings in the last 30 minutes
- Report any OOMKilled, FailedMount, FailedScheduling, or BackOff events

## Only Report Problems
- If pod is healthy, Flux is reconciled, and no warning events: reply HEARTBEAT_OK
- Don't repeat known issues from previous heartbeats unless status changed
