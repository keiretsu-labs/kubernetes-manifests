# Talos bootstrap structure (`clusters/talos-<location>/bootstrap/talos/`)

Each Talos cluster uses **talhelper** (`talconfig.yaml`) + per-node patches to
generate machine configs. Managed via `mise run <task>` (Taskfile.yaml).

## Layout

```
bootstrap/talos/
├── talconfig.yaml            # cluster config: nodes, patches, schematics
├── talsecret.sops.yaml       # encrypted secrets
├── Taskfile.yaml             # init, genconfig, apply, upgrade, ...
├── patches/
│   ├── global/               # all nodes (kubelet, sysctls, hostdns,
│   │                         #  machine-logging — IP differs per cluster:
│   │                         #  10.<loc>.69.51:5170)
│   ├── controller/           # control-plane only (api-access, disable-proxy,
│   │                         #  etcd-metrics, kubelet-certs)
│   └── node/                 # per-node overrides (shiro-intel, spark-0/1, orin-0)
└── clusterconfig/            # generated machine configs (gitignored)
```

## talconfig.yaml essentials

- `cniConfig: { name: none }` — Cilium installed separately, kube-proxy disabled
- Single VIP per cluster for API HA (192.168.X.25)
- Kernel args: `net.ifnames=0`, `mitigations=off`, `apparmor=0`,
  `cpufreq.default_governor=performance`
- `clusterPodNets` / `clusterSvcNets` per location (see AGENTS.md CIDRs)

Cluster differences:
- **Robbinsdale:** 3 CP nodes, no workers
- **Ottawa:** bonded X710 SFP+ NICs, AMD P-State, NUT client, i915/Intel GPU
- **St. Petersburg:** arm64 (Jetson Orin + DGX Spark GB10), NVIDIA GPU
  extensions, RDMA

## Adding a system extension

Add `- siderolabs/<extension>` to `officialExtensions` in the relevant
schematic (`controlPlane.schematic`, `worker.schematic`, or per-node
`.schematic`), then `talosctl upgrade` each node — it pulls a new factory
image with the extensions baked in.

Gotchas (from operations):
- `talosctl upgrade` from a workstation completes the installer but does NOT
  reboot — always follow with `talosctl reboot` and wait NotReady→Ready.
- Talos v1.13 blocks file creation outside `/var` — use `op: overwrite` on the
  existing `20-customization.part` for containerd config dropins.

## Robbinsdale tuppr rollout (2026-10-11/12)

Robbinsdale has 3 nodes (stone 20c/64Gi, tank 12c/64Gi, titan 12c/32Gi). The
v1.13.11 rollout stalled twice. Every cause and its fix:

| Symptom | Cause | Fix |
|---|---|---|
| stone drained, uncordoned and re-drained every ~15s; its OSDs bounced, PGs inactive; tank absorbed ~80-100 pods per cycle (2026-10-11) | `spec.drain.enabled` / `policy.waitForVolumeDetach` make tuppr drain the node itself; it gives up on the first PDB 429 and rolls back | Removed on all clusters. `tools/check-versions.sh` invariant 6 fails CI if either returns. talosctl now drains with `--drain-timeout`. |
| drain of stone blocked on `rook-ceph-mds-test-b` | MDS pods carry required anti-affinity against every `app=rook-ceph-mds` pod; 4 MDS (`filesystem` + orphan `test` CephFilesystem) on 3 nodes leaves the 4th unschedulable, so the `test` PDB never allows an eviction | Orphan `test` CephFilesystem (not in Git, 0 clients, 0 bytes) deleted 2026-10-12; 2 MDS on 3 nodes now |
| drain of titan blocked on `immich-postgres-2` / `tracearr-postgres-2` | CNPG only switches a primary off an unschedulable node to a replica on a schedulable node; the replicas were on a manually cordoned tank | Do not cordon nodes by hand during a rollout |
| PGs inactive (`undersized+peered`) while one host is down | `filesystem-replicated` and the orphan rgw pools use CRUSH rules that `choose_firstn type osd`, so two replicas can share a host; the git spec says `failureDomain: host` but the live rule was never changed | `enableCrushUpdates: true` on the dataPool (Rook v1.21 skips rule changes without it) moved it to `filesystem-replicated_host`; the orphan rgw/test pools, rules and EC profiles were removed 2026-10-12 |

Do not cordon tank (or any node) by hand during a rollout. It strands CNPG
switchover candidates and MDS standbys. Resume by removing the
`tuppr.home-operations.com/suspend` annotation in Git once all PGs are
active+clean and mons are 3/3.
