---
name: Cluster Context
description: >
  OpenClaw pod architecture, volumes, networking, secrets, and provider
  configuration reference.

  Use when: Debugging container, mount, networking, or credential issues.
  Also use when you need to understand pod structure, check which providers
  are configured, verify volume mounts, or inspect secrets configuration.

  Don't use when: Debugging pod crashes (use pod-troubleshooting). Don't use
  for Flux issues (use flux-debugging). Don't use for deploying changes
  (use gitops-deploy). This is a reference skill, not a diagnostic workflow.

  Outputs: Architecture reference information. No artifacts — this skill
  provides context for other skills to use.
requires: [kubectl]
---

# Cluster Context

## Routing

### Use This Skill When
- You need to know the pod architecture (containers, init containers, volumes)
- Checking which model providers are configured and their API key setup
- Verifying volume mount paths or networking configuration
- Understanding the init container workflow
- Someone asks "how is the pod set up?" or "what containers are running?"

### Don't Use This Skill When
- Pod is crashing → use **pod-troubleshooting** (it has diagnostic steps)
- Flux won't reconcile → use **flux-debugging**
- Deploying changes → use **gitops-deploy**
- Inspecting images in registry → use **zot-registry**
- Checking health across all clusters → use **cluster-health** (dyson)
- This is a reference, not a runbook — use it to understand, then switch to the right diagnostic skill

## Pod Architecture

Single-replica Deployment in `openclaw` namespace:

```
Pod: openclaw
  initContainers:
    sysctler        -> enables IP forwarding for Tailscale
    init-workspace  -> copies workspace content from OCI ImageVolume to data PVC
  containers:
    openclaw        -> OpenClaw server (oci.killinit.cc/openclaw/openclaw:latest)
    tailscale       -> Tailscale sidecar for mesh networking
```

## Model Providers

| Provider | Model | Use Case |
|----------|-------|----------|
| `aperture` | `MiniMax-M2.5` | Default — strong reasoning, 204k context |

## Volumes

| Volume | Type | Mount Path | Purpose |
|--------|------|------------|---------|
| `data` | PVC (openclaw-data, 5Gi Ceph RBD) | `/home/node/.openclaw/` | Persistent agent state |
| `workspace` | ImageVolume (oci.killinit.cc/openclaw/workspace:latest) | `/opt/workspace` | Read-only workspace content |
| `config` | ConfigMap (openclaw-config) | `/opt/config` | Config files, copied by init container |

## Networking

- Service `openclaw-main` on port 18789
- HTTPRoute through Gateway API (`ts` gateway in `home` namespace)
- Hostname: `openclaw.${CLUSTER_DOMAIN}` (Flux-substituted)


## Secrets

| Secret | Keys |
|--------|------|
| `openclaw-secrets` (SOPS) | DISCORD_BOT_TOKEN, OPENCLAW_GATEWAY_TOKEN |
| `ts-oauth` | Tailscale OAuth credentials (ephemeral + preauthorized) |
| `zot-pull-secret` | Registry credentials for `oci.killinit.cc` |

### SOPS Credential Pipeline (kubernetes-manifests repo)

Secrets for all cluster apps flow through SOPS + Flux postBuild substitution:
- **Cross-cluster:** `clusters/common/flux/vars/common-secrets.sops.yaml` → `common-secrets` Secret
- **Per-cluster:** `clusters/talos-*/flux/vars/cluster-secrets.sops.yaml` → `cluster-secrets` Secret
- **PGP key:** `FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5` (stored in `sops-gpg` Secret)
- **Delivery:** `${VAR}` in manifests is replaced by Flux before apply

For the full credential flow (patterns, examples, debugging), see **Morty's sops-credentials skill**.

## Inspection Commands

```bash
# Container images running
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq -r '.items[0].spec.containers[].image'

# Volume mounts
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | \
  jq '.items[0].spec.containers[0].volumeMounts[] | {name, mountPath}'

# Provider config
kubectl exec deployment/openclaw -c openclaw -n openclaw -- \
  jq '.models.providers | keys' /home/node/.openclaw/clawdbot.json

# Env vars (for API key resolution)
kubectl exec deployment/openclaw -c openclaw -n openclaw -- env | sort

# Pull secret verification
kubectl get secret zot-pull-secret -n openclaw -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
```
