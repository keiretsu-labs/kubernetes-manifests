# Static-pod / hostPath token-mount audit (2026-10-18)

Findings-only: which pods mount `/var/run/secrets` or hostPath volumes beyond
the projected SA token, and whether any pod reaches node credential material
(`/etc/kubernetes`, kubelet dirs, containerd socket). No change.

## hostPath census (49 hits, 20 files; per-path uniques)

| Path | Who | Credential-bearing? |
|---|---|---|
| `/var/lib/kubelet/device-plugins`, `plugins_registry`, `/var/lib/kubelet` | rdma-shared-dp, gpu-operator, nfd, kata, rbd-device-observer, generic-device-plugin ×3 | No — sockets/devices only, no kubelet config or tokens |
| `/var/run/netns(/)` | multus patch (ott+sp), cni-dhcp | No — network namespaces |
| `/var/run/containerd/containerd.sock` | tracee DS only | Socket = container API, not credentials; tracee is kube-system node-obsv, by design |
| `/var/run/secrets-store-csi-providers` | tailscale-csi-provider DS | CSI provider socket dir (tailscale plugin), not SA token |
| `/etc/os-release`, `/usr/lib`, `/lib`, `/sys/*`, `/proc/swaps`, `/boot`, `/dev/*` | tracee, nfd, irqbalance, derper, rdma, model-serving (infiniband), npd, device-plugins | Read-only host facts/devices |
| `/etc/kubernetes/node-feature-discovery/features.d/` | NFD only | Feature labels dir, not pki |
| `/var/log` | tracee, npd | logs |

**No pod mounts `/etc/kubernetes` or `/etc/kubernetes/pki`.** The only
`/etc/kubernetes/*` hostPath in the fleet is NFD's `features.d/` labels dir.
Zero `admin.conf`/`controller-manager.conf`/`kubelet.kubeconfig` references —
node creds stay inside the nodes (see kubelet-node-credential-surface.md).

## /var/run/secrets usage

- Projected SA token (`.../serviceaccount`) is read in-script by the bot
  sync Jobs, image-probe, quota-exporter, rbd-observer entrypoint — the
  standard pattern; nothing remounts it elsewhere.
- Custom token mounts under `/var/run/secrets/<name>` are plain Secret
  projections, not host paths: grafana-mcp (`grafana-mcp-token`) and
  woodpecker stranded-janitor — both already inventoried in the secret-scope
  work.
- `automountServiceAccountToken: false` on 8 workloads (bhaiya bots, mcp
  servers, tracee, quota-exporter, mimir-rule-completeness) — the hardening
  direction, already applied where the SA is unused.

## Host-network pods (9)

model-serving, home-assistant ott+rb, cni-dhcp, irqbalance ×2,
rdma-shared-dp, tailscale-system DS — hostNetworking without hostPath creds;
tailscale-system is kernel-TUN by charter.

## Findings

| # | sev | note |
|---|---|---|
| T1 | Info | No pod touches `/etc/kubernetes` beyond NFD's features.d; no kubeconfig/pki hostPath anywhere. Node credential surface confirmed clean (matches C1/C2 of the credential-surface doc). |
| T2 | Info | containerd.sock mount = tracee only (node observability DS, kube-system, automount false). Acceptable; it is the documented tracee pattern. |
| T3 | Info | All custom `/var/run/secrets/*` mounts are Secret projections, not hostPaths; no token duplication. |
| T4 | Info | 8 workloads already `automountServiceAccountToken: false`; remaining candidates are app-scoped and low value — no action. |

**Verdict: no-finding.** Static-pod/hostPath token surface is minimal and
already hardened; nothing to change.

Re-derive: `git grep -n "hostPath" -A2 -- kubernetes/ | grep "path:" | sort | uniq -c`
