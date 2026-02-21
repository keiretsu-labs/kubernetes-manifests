# Pod Failure Reference

## ImagePullBackOff

Registry auth or image tag issue.

```bash
# Check events for the pull error
kubectl describe pod -l app.kubernetes.io/name=openclaw -n openclaw | grep -A3 "Failed"

# Verify pull secret
kubectl get secret zot-pull-secret -n openclaw -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .

# Test image exists
crane manifest oci.killinit.cc/openclaw/openclaw:latest
crane manifest oci.killinit.cc/openclaw/workspace:latest
```

## CrashLoopBackOff

Container starts then exits repeatedly.

```bash
# Check exit code
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq '.items[0].status.containerStatuses[] | {name, restartCount, state}'

# Previous container logs (the crash)
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --previous --tail=100

# Check resource limits
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq '.items[0].spec.containers[] | {name, resources}'
```

## Init:Error

Init container failed — workspace copy or sysctl setup.

```bash
# Check which init container failed
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq '.items[0].status.initContainerStatuses[] | {name, state}'

# Get init container logs
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c init-workspace
```

## OOMKilled

Container exceeded memory limit.

```bash
# Confirm OOM
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq '.items[0].status.containerStatuses[] | select(.lastState.terminated.reason=="OOMKilled")'

# Check current memory limits
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq '.items[0].spec.containers[] | {name, resources}'
```

## EBUSY (Config Write Failure)

OpenClaw does atomic writes (rename) to config files. If the config is mounted directly from a ConfigMap (subPath), it will fail with EBUSY.

**Fix:** Config must be copied to an emptyDir by the init container. The main container only mounts the emptyDir — never the ConfigMap directly.

## Live Debugging

```bash
# Exec into the running openclaw container
kubectl exec -it deployment/openclaw -c openclaw -n openclaw -- /bin/sh

# Check workspace files
kubectl exec deployment/openclaw -c openclaw -n openclaw -- ls -la /home/node/.openclaw/workspaces/

# Check config
kubectl exec deployment/openclaw -c openclaw -n openclaw -- cat /home/node/.openclaw/clawdbot.json

# Check env vars (for API key resolution)
kubectl exec deployment/openclaw -c openclaw -n openclaw -- env | sort
```
