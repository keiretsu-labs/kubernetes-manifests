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

## Robbinsdale tuppr rollout: cordon tank during drains (2026-10-11)

Robbinsdale has 3 nodes (stone 20c/64Gi, tank 12c/64Gi, titan 12c/32Gi). On
2026-10-10/11 each tuppr drain of stone pushed ~80-100 pods onto tank (up to 163
pods, load ~130 on 12 cores): osd.10 liveness-flapped, PGs went briefly inactive,
new pods failed sandbox networking. tuppr's PreferNoSchedule
`tuppr.home-operations.com/outdated` taint on not-yet-upgraded nodes makes the
already-upgraded node the only preferred target.

When resuming (remove the `tuppr.home-operations.com/suspend` annotation on
`TalosUpgrade/talos` in
`kubernetes/apps/base/tuppr/tuppr-config-robbinsdale/config/talos-upgrade.yaml`):

1. Gates: all PGs active+clean, mons 3/3 on 3 nodes, no OSD restarts for 1h,
   pods per node roughly even (descheduler PodCountBalance profile).
2. Before each drain of stone or titan, `kubectl cordon tank` (unless tank is
   the node being upgraded) so displaced pods go to the other node.
3. Watch `ceph pg stat` / `ceph mon stat`. On any inactive PG or mon down,
   re-add the suspend annotation in Git (a live annotation is stripped by Flux),
   then cordon/evict to rebalance.
4. After the node is back Ready and Ceph is active+clean, `kubectl uncordon tank`.
