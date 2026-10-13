# Talos bootstrap structure (`clusters/talos-<location>/bootstrap/talos/`)

Each Talos cluster is described by a [topf](https://postfinance.github.io/topf)
`topf.yaml` plus layered patch files. topf generates the machine configs with
the Talos machinery library and applies them node by node. Run it through
`mise run <task>` (Taskfile.yaml) from `clusters/talos-<location>/`.

## Layout

```
bootstrap/talos/
├── topf.yaml                 # cluster name, endpoint, versions, nodes, schematic
├── schematic*.yaml           # Image Factory customizations (topf hashes them locally)
├── talsecret.sops.yaml       # encrypted secrets bundle (topf secretsPath)
├── Taskfile.yaml             # init, genconfig, diff, apply, bootstrap, ...
├── all/                      # every node (kubelet, sysctls, hostdns, hostname,
│                             #  machine-logging — IP differs per cluster:
│                             #  10.<loc>.69.51:5170)
├── control-plane/            # control-plane only (api-access, disable-proxy,
│                             #  etcd-metrics, kubelet-certs, metrics-server)
├── worker/                   # workers only (Ottawa, St. Petersburg)
├── node/<host>/              # per node: install disk, links/bond/VIP, overrides
└── clusterconfig/            # rendered machine configs + talosconfig (gitignored)
```

Patches merge in order `all/` → `<role>/` → `node/<host>/`, and lexically
within a directory. `.yaml.tpl` files are Go templates (sprig available) with
`.Node.Host`, `.Node.Role`, `.TalosVersion`, `.SchematicID` and
`.Node.RuntimeData.TalosVersion` (the live node's version). JSON patches are not
supported; delete a key with `$patch: delete`.

## Workflow

| Task | What it does |
|---|---|
| `mise run diff` | `topf apply --dry-run`: diff of every node's live config vs git; exit 2 when anything differs |
| `mise run apply` | `topf apply`: one node at a time; aborts if a node is unhealthy, waits for each to stay Ready |
| `mise run apply-staged` | Same, `--mode=staged` (takes effect on next reboot) |
| `mise run genconfig` | Render `clusterconfig/<host>.yaml` and `clusterconfig/talosconfig` |
| `mise run upgrade` | `topf upgrade`: manual fallback for tuppr; drains, one control plane at a time |
| `mise run iso` | Download the ISO for the control-plane schematic |

`mise run diff` prints Talos's dry-run summary per node. Read it before every
apply: a summary that says the change needs a reboot means apply reboots that node.

## Cluster essentials

- `cluster.network.cni.name: none` — Cilium installed separately, kube-proxy disabled
- Single VIP per cluster for API HA (192.168.X.25), a `Layer2VIPConfig` per control-plane node
- Kernel args live in the schematics: `net.ifnames=0`, `mitigations=off`, `apparmor=0`,
  `cpufreq.default_governor=performance`
- Pod/service subnets per location in `all/00-cluster.yaml` (see AGENTS.md CIDRs)

Cluster differences:
- **Robbinsdale:** 3 CP nodes, no workers
- **Ottawa:** bonded X710 SFP+ NICs, AMD P-State, NUT client, i915/Intel GPU on shiro (`schematic-shiro.yaml`)
- **St. Petersburg:** arm64 (Jetson Orin + DGX Spark GB10), NVIDIA GPU
  extensions, RDMA. orin-0 has 8 GiB, so `node/orin-0/20-memory.yaml` overrides
  the Spark-sized kubelet reservations from `all/`.

## Adding a system extension

Add `- siderolabs/<extension>` to `officialExtensions` in the relevant
`schematic*.yaml`, run `topf schematic-ids --submit-to-factory` once so the
factory knows the new ID, then upgrade each node (tuppr, or `mise run upgrade`)
— it pulls a new factory image with the extensions baked in.

Gotchas (from operations):
- `talosctl upgrade` from a workstation completes the installer but does NOT
  reboot — always follow with `talosctl reboot` and wait NotReady→Ready.
- Talos v1.13 blocks file creation outside `/var` — use `op: overwrite` on the
  existing `20-customization.part` for containerd config dropins.
- Talos 1.14 config documents (`KubeletConfig`, `UnattendedInstallConfig`, ...)
  conflict with the classic v1alpha1 fields. topf picks the config contract from
  each node's running version, so patches that 1.14 rejects are `.yaml.tpl`
  files branching on `.Node.RuntimeData.TalosVersion | default .TalosVersion`.

## Talos 1.14 (version-gated patches)

The same tree renders the classic contract for 1.13 nodes and the 1.14
contract for 1.14 nodes, so a tuppr rollout can stop half way and
`mise run diff` still works on every node.

- `all/99-talos-114.yaml.tpl`, `control-plane/90-talos-114.yaml.tpl` and
  `control-plane/91-talos-114-authn.yaml.tpl` only render on 1.14. They delete
  the generated documents that our classic patches still own
  (`KubeletConfig`, `KubeNodeConfig`, `KubeNetworkConfig`, `ResolverConfig`,
  `KubePrismConfig` on control planes) and pin every new 1.14 default to the
  pre-1.14 behaviour: workload isolation off, no Flannel, no weekly trim, no
  EPHEMERAL `secure` mount, no API server startup probes, anonymous auth off.
- The kubelet stays classic on purpose: the 1.14 `KubeletConfig` document has
  no extra mounts, and `/var/local-path-provisioner` is a kubelet bind mount.
- Install disk, discovery, API server, controller-manager, scheduler, proxy
  and PodSecurity patches emit the 1.14 document on 1.14 nodes and the classic
  field on 1.13 nodes.
- Effective settings were compared with the Talos 1.14.2 `config.Provider`
  accessors for every node. The only differences are representation changes
  (discovery endpoint name, explicit Node/RBAC authorizers, the etcd encryption
  document carrying the same `key2` secretbox key) plus one hard-coded 1.14
  addition: a read-only `/etc/ssl/certs` mount in kube-apiserver.

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
