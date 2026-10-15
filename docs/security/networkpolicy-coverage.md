# NetworkPolicy coverage map

Audit of which namespaces have any `NetworkPolicy` / `CiliumNetworkPolicy`
objects, per cluster. Generated from the git tree (2026-10-15, main
`56ed4684e`); re-derive with the greps below when audited again.

This is documentation only — no policy changes are proposed here.

## Method

```sh
git grep -l "kind: NetworkPolicy" -- clusters/ kubernetes/
git grep -l "kind: CiliumNetworkPolicy" -- kubernetes/
```

Namespace of each policy = explicit `metadata.namespace`, else the nearest
`kustomization.yaml` `namespace:`, else the pointer-directory name. A namespace
counts as covered if any policy object lands in it (base policies count for
every cluster whose pointer tree contains that namespace).

Two semantics apply and are noted per entry:

- `NetworkPolicy` — kube native; default-deny only if a policy selects the pods
  AND pod traffic is otherwise policy-enforced. Cilium is the CNI, so native
  NetworkPolicy is enforced by Cilium.
- `CiliumNetworkPolicy` — Cilium-native; richer L7. With CNPs present and
  `policy enforcement` default (no global default-deny), unselected pods are
  unaffected; a CNP never makes a namespace default-deny by itself.

## Policies in the repo (16 objects)

| namespace | kind | name | clusters | source |
|---|---|---|---|---|
| `bhaiya` | CNP | kubernetes-manifests-bot-viewer-apiserver | ot | `base/bhaiya/kubernetes-manifests-bot-viewer/apiserver-egress.yaml` |
| `bhaiya` | CNP | kubernetes-manifests-bot-viewer-sync-apiserver | ot | same dir, `sync-egress.yaml` |
| `cliproxy` | CNP | cliproxy-quota-exporter | ot | `base/cliproxy/cliproxy/app/quota-exporter.yaml` |
| `firefly` | CNP | firefly-mcp-ingress | ot | `base/firefly/firefly/mcp/networkpolicy.yaml` |
| `flux-system` | NP | allow-gatus / allow-monitoring / allow-webhooks | ot/rb/sp | `base/flux-system/flux-system-common/monitoring/*.yaml` |
| `flux-system` | NP | allow-monitoring | sp | `base/flux-system/flux-system-stpetersburg/app/networkpolicy-monitoring.yaml` |
| `garage` | CNP | garage-rpc-egress-guard | ot/rb/sp | `base/garage/garage-rpc-egress-guard-ottawa/` |
| `garage` | CNP | garage-gateway-ingress | ot/rb/sp | `base/garage/garage/garage-gateway-ingress.yaml` |
| `kube-system` | CNP | kata-runtime-observer-metrics | ot/rb/sp | `base/kata-containers/.../tracee-networkpolicy.yaml` |
| `kube-system` | CNP | node-problem-detector-metrics | ot/rb/sp | `base/kube-system/node-health/app/npd-networkpolicy.yaml` |
| `monitoring` | CNP | grafana-ingress / grafana-mcp-ingress | ot/rb/sp | `base/monitoring/grafana/*` |
| `tempvm` | NP | tempvm | ot | `base/tempvm/tempvm/app/networkpolicy.yaml` |
| `zot` | NP | dragonfly-zot-metrics | ot | `base/zot/zot-cache-ottawa/servicemonitor.yaml` |

Plus: the Flux bootstrap kustomization
(`clusters/common/bootstrap/flux/kustomization.yaml`) **deletes** the default
flux NetworkPolicies — flux-system relies on the three allow-* policies above.

## Coverage by cluster

“Covered” = at least one policy object lands in the namespace on that cluster.
System namespaces outside `kubernetes/apps/*` that contain workloads
(`kube-system`, `rook-ceph`, `csi-addons`, `cert-manager`, … operator ns) are
included in the counts via the standard operator-namespace set.

### Ottawa — 9 of ~66 covered

Covered: `bhaiya`, `cliproxy`, `firefly`, `flux-system`, `garage`,
`kube-system`, `monitoring`, `tempvm`, `zot`.

Without any NetworkPolicy (57):
`agent-sandbox-system, arc-systems, auth, bhaiya-v2, border0, bot,
cert-manager, cloudflare, cnpg-system, csi-addons, csi-driver-smb, default,
descheduler, dns, dragonfly-operator-system, envoy-gateway-system,
external-secrets, firecrawl, fluent-bit, forgejo, garage-operator-system, gatus,
gpu-operator, gvisor, hermes, home, homer-operator, hubble-ui, immich, k8gb,
k8s-gpu-dra-driver, kata-containers, kopiur, lan, litellm, local-path-storage,
media, metrics-server, mimir, node-feature-discovery, nvidia,
open-cluster-management, open-cluster-management-agent, opencost, rook-ceph,
searxng, snapshot-controller, spegel, tailscale, tailscale-examples,
tailscale-pam, tailscale-system, teslamate, tuppr, victoria-logs, vpa-system,
woodpecker`

### Robbinsdale — 4 of ~48 covered

Covered: `flux-system`, `garage`, `kube-system`, `monitoring`.

Without any NetworkPolicy (44):
`agent-sandbox-system, arc-systems, cert-manager, cloudflare, cnpg-system,
csi-addons, csi-driver-smb, default, descheduler, dns,
dragonfly-operator-system, envoy-gateway-system, external-secrets, fluent-bit,
garage-operator-system, gatus, gpu-operator, gvisor, home, homer-operator,
hubble-ui, immich, k8gb, kopiur, local-path-storage, media, metrics-server,
mimir, node-feature-discovery, nvidia, open-cluster-management-agent,
rook-ceph, snapshot-controller, speedtest, spegel, strimzi, tailscale,
tailscale-examples, tailscale-system, tinyauth-egress, tuppr, victoria-logs,
vpa-system, woodpecker`

### St. Petersburg — 4 of ~45 covered

Covered: `flux-system`, `garage`, `kube-system`, `monitoring`.

Without any NetworkPolicy (41):
`agent-sandbox-system, ai, arc-systems, cert-manager, cloudflare, cnpg-system,
csi-addons, default, descheduler, dns, envoy-gateway-system, external-secrets,
fluent-bit, garage-operator-system, gatus, gpu-operator, gvisor, home,
home-assistant, homer-operator, hubble-ui, k8gb, kopiur, local-path-storage,
lws-system, metrics-server, mimir, node-feature-discovery, nvidia,
open-cluster-management-agent, rdma-shared-dp, rook-ceph,
snapshot-controller, spegel, tailscale, tailscale-examples, tailscale-system,
tinyauth-egress, tuppr, victoria-logs, vpa-system`

## Reading the gaps

- The cluster-wide posture is **allow-by-default**: no namespace here ships a
  default-deny ingress/egress pair. Policies that exist are targeted guards
  (metrics scraping, ingress paths, the garage RPC egress guard) rather than
  segmentation.
- Higher-value candidates for future default-deny pairs, by exposure and
  blast radius: `forgejo`, `media`, `immich`, `woodpecker`, `tinyauth-egress`
  consumers, `hermes`, `firefly` (app pod, MCP guard exists), `searxng`,
`teslamate`. System planes (`cert-manager`, `cnpg-system`, `envoy-gateway-system`,
`external-secrets`, `rook-ceph`, `tailscale*`) carry cluster-critical egress
and should be scoped last, with explicit allowlists.
- Host-network workloads (`home`/home-assistant Ottawa, `ai` GPU pods) need
  node-level policy (Cilium node policies / host firewall), not plain
  NetworkPolicy — out of scope for a namespace map.

Regenerate this file whenever a policy or namespace is added; the counts above
decay quickly.
