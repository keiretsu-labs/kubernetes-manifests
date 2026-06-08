# Network Storage Layer — Replacing Local-Path Provisioner

## Problem

Losing a single node (spark-0 in stpetersburg, 2026-06-08) caused data-inaccessibility for workloads using local-path PVs:
- Garage gateway StatefulSets with node-affine local volumes
- Jellyfin PVs pinned to the failed node
- PV node affinity prevented rescheduling until the node recovered

## Why it matters

Local-path provisioner is simple and fast, but creates a hard coupling between data and a specific node. In a 3-node cluster, losing one node means losing all data stored on it — there's no replication, no rebalancing. You get the fault tolerance of the node, not the cluster.

## Candidates to replace it

| Option | Pros | Cons |
|---|---|---|
| **Rook/Ceph** | Already running on robbinsdale + ottawa; proven distributed storage; replication + self-healing | Heavy; needs dedicated disks (StP has NVMe); extra CPU/memory tax; Talos requires specific OSD config |
| **Mayastor** | Lightweight; purpose-built for NVMe; great for Talos | Less mature; stpetersburg is arm64 — Mayastor may not support it |
| **Longhorn** | Built for k8s; replication; UI; arm64 support | Performance overhead on NVMe; another operator to manage |
| **StoRidge (Rancher)** | Lightweight HA block storage | Might be overkill for a 3-node arm64 cluster |
| **DEMO + tailscale** | Keep local-path + back up critical data to a remote Garage instance via VolSync; no distributed storage complexity | Not HA; recovery involves restore, not failover |

## Decision needed

Which direction to go for stpetersburg specifically. The rest of the infra already has Ceph on ottawa/robbinsdale. StP's arm64 and GPU-focused nature might make Longhorn or a backup-based approach the best fit.