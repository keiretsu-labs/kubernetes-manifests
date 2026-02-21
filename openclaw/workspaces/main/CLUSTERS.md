# Clusters

Three production clusters across three physical sites. Connected via Tailscale mesh. All GitOps via Flux CD from `keiretsu-labs/kubernetes-manifests`.

## Ottawa (talos-ottawa)

| Key | Value |
|-----|-------|
| Type | Talos Linux |
| Nodes | 3: rei, asuka, kaji |
| kubectl context | `kubernetes-ottawa.keiretsu.ts.net` |
| Pod CIDR | 10.3.0.0/16 |
| Service CIDR | 10.2.0.0/16 |
| LAN | 192.168.169.0/24 |
| Storage | Rook-Ceph, 3 OSDs |
| Priority | Best-effort (media) |

**Workloads:** jellyfin, plex, sonarr-*, radarr-*, bazarr-*, lidarr, qbittorrent, sabnzbd, prowlarr, autobrr — 30+ *arr stack apps

**Quirks:**
- Ceph health warnings after node restarts are transient — wait 5m before escalating
- Flux source-controller can lag webhook delivery — force reconcile if revision is stale

---

## Robbinsdale (talos-robbinsdale)

| Key | Value |
|-----|-------|
| Type | Talos Linux |
| Nodes | 5: silver, stone, tank, titan, vault |
| kubectl context | `kubernetes-robbinsdale.keiretsu.ts.net` |
| Pod CIDR | 10.1.0.0/16 |
| Service CIDR | 10.0.0.0/16 |
| LAN | 192.168.50.0/24 |
| Storage | Rook-Ceph, 5 OSDs |
| Priority | Primary production |

**Workloads:** home-assistant, frigate, immich, jellyfin, monitoring, cert-manager, Rook-Ceph primary

**Quirks:**
- 5-node Ceph — higher resilience but OSD node labels matter
- All nodes have Mayastor labels via `base.patch`

---

## St. Petersburg (talos-stpetersburg)

| Key | Value |
|-----|-------|
| Type | K3s |
| kubectl context | `kubernetes-stpetersburg.keiretsu.ts.net` |
| Pod CIDR | 10.5.0.0/16 |
| Service CIDR | 10.4.0.0/16 |
| LAN | 192.168.73.0/24 |
| Storage | local-path-provisioner |
| Priority | Best-effort (AI/ML) |

**Workloads:** ollama, kserve, kuberay, gpu-operator

**Quirks:**
- K3s not Talos — use `k3s` CLI not `talosctl` for OS-level ops
- GPU time-slicing via gpu-operator
- No Ceph — local-path only, no data redundancy

---

## Cross-Cluster Snippets

```bash
# Pods not Running across all clusters
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  kubectl --context=$ctx get pods -A --field-selector=status.phase!=Running 2>/dev/null | grep -v Completed
done

# Flux failures across all clusters
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  flux --context=$ctx get kustomization -A 2>/dev/null | grep -v "True"
done
```
