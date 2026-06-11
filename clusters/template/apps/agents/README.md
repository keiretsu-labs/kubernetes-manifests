# Agents Namespace Template

This directory contains the **reference template** for the `agents` namespace architecture used in this GitOps monorepo. It codifies the standard patterns for deploying Hermes AI agents with Envoy OIDC-gated web UIs.

## Structure

```
clusters/template/apps/agents/
├── README.md                          # this file
├── namespace.yaml                     # agents namespace definition
├── kustomization.yaml                 # top-level kustomization (resolves ks.yaml)
├── ks.yaml                            # Flux Kustomization for shared app resources
├── app/
│   ├── bucket.yaml                    # shared GarageBucket for agent S3 storage
│   ├── egress.yaml                    # Tailscale egress services (ai, aperture)
│   ├── kustomization.yaml             # app-level resources (shared infra only)
│   ├── add-agent-web.sh               # automation script (Pocket ID + overlay)
│   ├── example-agent/                 # example agent overlay (self-contained)
│   │   ├── deployment.yaml
│   │   ├── configmap.yaml
│   │   ├── secret.yaml
│   │   └── kustomization.yaml
│   └── _component/
│       └── agent-web/                 # reusable kustomize component
│           ├── kustomization.yaml     # Component + replacements
│           ├── service.yaml           # ClusterIP service (8642/9119)
│           ├── service-tailscale.yaml # Tailscale LB service
│           ├── storagestack.yaml      # VolSync PVC
│           ├── garagekey.yaml         # S3 access key (allBuckets:read)
│           ├── httproute.yaml         # Dashboard UI via ts gateway
│           ├── httproute-web.yaml     # Web UI via Garage S3 + URLRewrite
│           ├── securitypolicy.yaml    # Envoy OIDC gating (Pocket ID)
│           └── oidc-secret.yaml       # Shared OIDC client secret
```

## Architecture

Agents in this namespace follow one of two patterns:

### Pattern A: Agent with Web UI + OIDC (recommended for new agents)

Uses the `_component/agent-web` component for networking, storage, S3 access, and OIDC gating. The overlay supplies only the agent-specific bits:

| Provided by component | Provided by overlay |
|---|---|
| Service (ClusterIP) | Deployment (hermes-agent container) |
| Service (Tailscale LB) | ConfigMap (`hermes-placeholder-config`) |
| StorageStack (PVC) | Secret (API keys, tokens) |
| GarageKey (S3) | `agent-meta` ConfigMap (via configMapGenerator) |
| HTTPRoute (ts gateway → dashboard) | |
| HTTPRoute (web → Garage S3 + OIDC) | |
| SecurityPolicy (Envoy OIDC) | |
| OIDC Secret | |

The overlay's `agent-meta` ConfigMap drives name/host/tag substitutions via the component's `replacements`:

```yaml
configMapGenerator:
  - name: agent-meta
    literals:
      - name=my-agent              # kebab-case agent name
      - host=my-agent.agents.${COMMON_DOMAIN}
      - clientID=<pocket-id-uuid>
      - size=20Gi
      - tailscaleTag=tag:k8s
```

### Pattern B: Agent without Web UI (simple agents like abtar, kartik)

Manual — just deployment + service + storagestack + garagekey. No `_component/agent-web` needed.

## Usage: Adding a New Agent

### Automated (recommended)

```bash
cd clusters/<cluster>/apps/agents/
./add-agent-web.sh my-agent [member-username ...]
```

This script:
1. Creates a Pocket ID OIDC client (`hermes-<name>`)
2. Creates a user group + adds members
3. Restricts the client to the group
4. Writes the overlay (`app/<name>/`) with deployment, configmap, secrets
5. SOPS-encrypts the secret
6. Writes `ks-<name>.yaml` Flux Kustomization
7. Registers it in the top-level `kustomization.yaml`
8. Validates the kustomize render

### Manual

1. Copy the `example-agent/` directory to `app/<name>/`
2. Edit the files:
   - `deployment.yaml` — match your agent's container config
   - `configmap.yaml` — set AGENT_NAME, AGENT_SYSTEM_PROMPT, integrations
   - `secret.yaml` — add real secrets, SOPS-encrypt
3. Update `kustomization.yaml`:
   - Set `agent-meta` literals (name, host, clientID, size, tailscaleTag)
   - Add per-agent patches for the ConfigMap
4. Create `ks-<name>.yaml` (copy from `ks.yaml`, adjust path)
5. Register in top-level `kustomization.yaml`
6. Validate: `kustomize build app/<name>/`

## Web Bucket (optional)

For agents that serve a static website via Garage S3 (like `portfolio-page.py` cron jobs), create a per-agent `GarageBucket` + `GarageKey`:

- `bucket.yaml` with `globalAlias: <name>-web` and `website.indexDocument: index.html`
- `garagekey-web.yaml` with `allBuckets: { read: true, write: true }`

Then the HTTPRoute-web URLRewrite targets `<name>-web.${COMMON_DOMAIN}` (the bucket alias).

## Scoping

This template lives at `clusters/template/` as a reference. Each real cluster (`talos-ottawa/`, `talos-robbinsdale/`, `talos-stpetersburg/`) carries its own copy under `apps/agents/` with:
- Active agent overlays
- Cluster-specific GarageKeys, StorageStacks, and Tailscale tags
- `ks-*.yaml` Flux Kustomizations mapped to the correct cluster path

When adding an agent to a real cluster, run the automation script from that cluster's `apps/agents/` directory, not from this template.

## Reference

For the live reference implementation, see:
- `clusters/talos-ottawa/apps/agents/` — teaspoon, assistant-raj, abtar, kartik, camofox
- `clusters/talos-ottawa/apps/agents/app/_component/hermes-group/` — multi-tenant group component