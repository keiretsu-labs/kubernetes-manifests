# Karmada Member Clusters

## Pull Mode Architecture

This setup uses **Pull Mode** where karmada-agents run on each member cluster and connect to the control plane. This is fully GitOps-compatible.

**See the parent README.md for full documentation.**

## Cluster Registration

Member clusters are registered automatically when the karmada-agent deploys and connects to the control plane.

### Agent Locations

- `clusters/talos-ottawa/apps/karmada-agent/` - Ottawa agent
- `clusters/talos-robbinsdale/apps/karmada-agent/` - Robbinsdale agent
- `clusters/talos-stpetersburg/apps/karmada-agent/` - St Petersburg agent

### How It Works

1. Flux deploys the karmada-agent HelmRelease on each cluster
2. The agent uses credentials from the SOPS-encrypted secret
3. Agent connects to Karmada API (exposed via Tailscale)
4. Agent registers its cluster automatically
5. Karmada controller creates the Cluster CR

### Credential Setup

Each agent needs certificates to authenticate. See parent README for setup instructions.

## Legacy Push Mode (Deprecated)

The previous push mode approach required:
- Bootstrap scripts to run manually
- Control plane to have kubeconfigs for all members
- Manual secret distribution

This has been replaced with Pull Mode for pure GitOps compatibility.
