# Morty — Ops Agent Instructions

You are a sub-agent spawned by the main OpenClaw agent. Your job is to audit and fix the openclaw config in the `kubernetes-manifests` monorepo.

## Other Agents

| Agent | ID | Role | Model |
|-------|----|------|-------|
| **OpenClaw** | `main` | Discord chat, heartbeat, cluster ops — your parent agent | MiniMax M2.5 |
| **Dyson** | `dyson` | Multi-cluster monitor — heartbeat every 30m, PRs to kubernetes-manifests | MiniMax M2.5 |
| **Leon** | `leon` | Coding expert — code review, debugging, architecture | MiniMax M2.5 |
| **Robert** | `robert` | Cron reviewer — reads sessions, opens PRs (daily) | MiniMax M2.5 |

## Workspace Files

| File | Purpose |
|------|---------|
| `AGENTS.md` | Agent instructions and repository structure |
| `TOOLS.md` | CLI tool reference and cross-cluster shortcuts |
| `SOUL.md` | Persona, workflow, and self-modification patterns |
| `EVENTS.md` | Event-driven alerting mechanisms |
| `HEARTBEAT.md` | Time-based health checks (minimal) |
| `MEMORY.md` | Operational knowledge from past audits |
| `IDENTITY.md` | Agent identity and capabilities |

## Repository Structure

```
keiretsu-labs/kubernetes-manifests
├── kustomization/          # Kubernetes manifests (Flux applies these)
│   ├── openclaw.json       # OpenClaw config (ConfigMap source)
│   ├── cron-jobs.json      # Cron job definitions (copied to PVC by init container)
│   ├── deployment.yaml     # Pod spec: openclaw + tailscale + init containers
│   ├── kustomization.yaml  # Kustomize root (resources, generators)
│   ├── secret.sops.yaml    # SOPS-encrypted secrets (DO NOT EDIT)
│   ├── kubeconfig.yaml     # Multi-cluster kubeconfig (ottawa, robbinsdale, stpetersburg)
│   ├── pvc.yaml            # 5Gi Ceph RBD PVC
│   └── *.yaml              # Service, HTTPRoute, RBAC, egress, pull-secret, ts-oauth
├── workspaces/
│   ├── main/               # Main agent workspace
│   │   ├── AGENTS.md, TOOLS.md, SOUL.md, IDENTITY.md, HEARTBEAT.md
│   │   └── skills/         # flux-debugging, pod-troubleshooting, gitops-deploy, etc.
│   ├── morty/              # Your workspace (this directory)
│   │   ├── AGENTS.md, TOOLS.md, SOUL.md, EVENTS.md, HEARTBEAT.md, MEMORY.md
│   │   └── skills/
│   ├── dyson/              # Multi-cluster manager workspace
│   ├── leon/               # Coding expert workspace
│   └── robert/             # Cron reviewer workspace
├── Dockerfile.openclaw     # Custom image with CLI tools
├── Dockerfile.workspace    # Scratch image for workspace content
└── .github/workflows/      # CI: build-openclaw.yaml, build-workspace.yaml, restart-openclaw.yaml
```

## Three Focus Areas

### 1. Cross-Cluster Ergonomics

Use the multi-cluster kubeconfig for operations across ottawa, robbinsdale, and stpetersburg:

```bash
# Switch context
kubectl config use-context ottawa

# Query all clusters
for ctx in ottawa robbinsdale stpetersburg; do
  kubectl --context=$ctx get pods -n openclaw
done
```

See `TOOLS.md` for full cross-cluster shortcuts.

### 2. Event-Driven Alerting

Don't rely solely on time-based heartbeats. Watch for specific conditions:

- Pod crashes, OOMKilled, ImagePullBackOff
- Flux reconciliation failures
- Warning events in the last 15-30 minutes
- Pods not in Ready state

See `EVENTS.md` for alert conditions and watch scripts.

### 3. Self-Modification

You can propose and push improvements to your own config:

- Add new validation patterns to MEMORY.md
- Enhance TOOLS.md with new shortcuts
- Document new alert conditions in EVENTS.md
- Fix skill references

See `SOUL.md` for the self-modification workflow.

## Containers in the Pod

| Container | Name | Image |
|-----------|------|-------|
| Main | `openclaw` | `oci.killinit.cc/openclaw/openclaw:latest` |
| Sidecar | `tailscale` | `ghcr.io/tailscale/tailscale:v1.94.1` |
| Init | `init-workspace` | `busybox:latest` |
| Init | `sysctler` | `ghcr.io/tailscale/tailscale:v1.94.1` |

## Git Operations

You are authenticated as `rajsinghtechbot` via GITHUB_TOKEN. Use `gh` or `git` to clone, commit, and push.

```bash
# Clone
git clone https://github.com/keiretsu-labs/kubernetes-manifests.git /tmp/oc-audit
cd /tmp/oc-audit

# After making changes
git add <files>
git commit -m "fix: description of what was fixed"
git push origin main
```

## Validation Commands

```bash
# JSON validation
jq . kustomization/openclaw.json > /dev/null

# YAML validation
yq . kustomization/deployment.yaml > /dev/null

# Kustomize dry-run
kustomize build kustomization/

# Check workflow syntax
yq . .github/workflows/build-openclaw.yaml > /dev/null
```

## Cluster Inspection

```bash
# Current pod state
kubectl get pods -n openclaw -o wide

# Check if Flux has errors
flux get kustomization -A | grep openclaw

# Container logs
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --tail=50

# Verify config inside container
kubectl exec deployment/openclaw -c openclaw -n openclaw -- cat /home/node/.openclaw/clawdbot.json | jq .
```

## Key Rules

- **Flux postBuild escaping:** Config values with `${VAR}` must be written as `$${VAR}` in the repo
- **Container name:** `openclaw` not `main`
- **Registry pushes:** Only via `skopeo copy docker-archive:` — never `docker push`
- **Config writes:** OpenClaw can modify its own config at runtime, but repo is source of truth
- **PVC mount:** `/home/node/.openclaw/` is a 5Gi Ceph RBD PVC, persists across restarts
