# Karmada + k8gb GSLB Application Template

Template for deploying a distributed application using Karmada for multi-cluster scheduling and k8gb for DNS-based global server load balancing through the CDN Envoy gateway.

## Two Deployment Paths

1. **`karmada/`** — Applied to the Karmada API server via the `karmada-workloads` Flux Kustomization (Ottawa). Karmada distributes the workload to member clusters.
2. **`gslb/`** — Applied to every cluster via `common/apps/k8gb/config/`. Creates the HTTPRoute and Gslb resource so k8gb can manage DNS across all clusters.

## Setup Steps

1. Copy `karmada/` contents to `clusters/talos-ottawa/apps/karmada-workloads/workloads/<app-name>/`
2. Add `<app-name>` to `clusters/talos-ottawa/apps/karmada-workloads/workloads/kustomization.yaml`
3. Copy `gslb/` contents into `clusters/common/apps/k8gb/config/` (rename `gslb.yaml` to `gslb-<app-name>.yaml`)
4. Add namespace and gslb file to `clusters/common/apps/k8gb/config/kustomization.yaml`
5. Replace all `REPLACE_*` placeholders with actual values

## Placeholders

| Placeholder | Description | Example |
|---|---|---|
| `REPLACE_APP_NAME` | Application name | `gatus` |
| `REPLACE_NAMESPACE` | Target namespace | `keiretsu-top` |
| `REPLACE_IMAGE` | Container image:tag | `twinproduction/gatus:v5.17.0` |
| `REPLACE_PORT` | Container port | `8080` |
| `REPLACE_HOSTNAME` | CDN hostname | `status.cdn.keiretsu.top` |

## Constraints

- **No Flux variables in karmada/ manifests.** The karmada-workloads Flux Kustomization applies via `kubeConfig` to the Karmada API. Any `postBuild` substitution resolves in Ottawa's context, not the target cluster's. Use hardcoded values only.
- **Flux variables work in gslb/ manifests.** These are applied per-cluster via the normal Flux pipeline with `postBuild` substitution.
- **Namespace must exist on all clusters.** The gslb/ side creates it via common/. The karmada/ side also creates it for propagation to member clusters.
