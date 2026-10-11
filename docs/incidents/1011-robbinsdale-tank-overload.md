# Robbinsdale tank CPU pressure and transient endpoint failures (2026-10-11)

## Finding and current state

Tank's persistent problem is CPU contention, with a restart or reconciliation
burst exposing Cilium's endpoint-create API limit. The earlier
`putEndpointIdTooManyRequests`, Garage webhook `no route to host`, and failed
`tuppr-config`/Kopiur reconciliations were reported before this inspection;
the current Cilium counters corroborate the 429s, but retained logs and events
do not establish the exact webhook-to-429 causal sequence. At 15:00 UTC,
`tuppr-config` and `kopiur-robbinsdale-repo` were both Ready at revision
`12fef7bf`, and the last six hours showed no new Cilium endpoint-create 429s.
The configuration reconciliation is therefore **already unblocked**. A Talos
rollout remains a separate, restart-causing decision requiring CPU headroom and
the control-plane checks in `AGENTS.md`.

The observations below are read-only snapshots on 2026-10-11 unless a window
is specified. Historical p95s use Mimir tenant `talos-robbinsdale`: a 5-minute
rate sampled hourly over seven days (about 168 samples). Short-lived pods have
too few hourly samples for a reliable p95 and are described separately.

| Signal | Evidence |
| --- | --- |
| CPU | `kubectl top node`: 9.34/11.95 allocatable cores (78%); seven-day p95 CPU busy time 11.91/12 cores, max 11.99. The current Mimir 5-minute rate splits into 5.44 user, 3.23 system, and 0.80 IRQ/softirq cores. |
| Pressure | Seven-day CPU PSI waiting p95 0.79 (long-lived node-exporter series), versus IO PSI waiting p95 0.06 and memory PSI waiting p95 0.008. The replacement exporter had only 12 hourly points, with CPU PSI p95 0.89. |
| Memory and pod slots | `kubectl top node`: 18,623 MiB (30%); `MemoryPressure=False`. 77 Running pods, 86 pod objects including completed pods, versus 250 allocatable slots. `DiskPressure=False` and `Ready=True`. Neither pod count nor memory capacity explains this failure. |
| Cilium | Tank's agent started 02:14 UTC and had 168 endpoint-create HTTP 429s: 59 `fail-limit-wait`, 109 `fail-parallel-wait`; the other two nodes had no 429 series at inspection. Its endpoint-create limit was 0.288 requests/s, burst 3, parallel limit 3, and mean processing duration 3.47 s. Increase over the last six hours was zero. This is a measured endpoint bottleneck, not evidence that the limit itself should be changed. |
| Flux | Both `tuppr-config` and `kopiur-robbinsdale-repo` were Ready at 14:57 UTC. Garage operator installation also reconciled successfully. Earlier webhook routing errors were not present in the retained recent events or operator log. |

### What is using tank

Current CPU readings vary with load. One `kubectl top pods --containers` snapshot
joined to pods assigned to tank showed Cilium 0.73 core, Prometheus agent 0.64,
Ceph osd.10 0.54, kube-apiserver 0.30, and Ceph mgr 0.34 across its containers.
The seven-day hourly p95s for long-lived pod instances were kube-apiserver 0.94,
Ceph osd.10 0.67, Prometheus agent 0.66, Cilium 0.54–0.58 for previous agent
instances, Immich server 0.62, and Garage storage 0.42 cores. These are
individual pod-instance series, not a complete accounting of the node's
roughly 12 busy cores; system, IRQ, kubelet, container runtime, and short-lived
pods also consume CPU. In particular, the instantaneous request of 2 cores
for Immich server exceeded its observed 0.62-core historical p95, while each
of tank's Ceph OSDs requests 0.5 core and osd.10's p95 exceeded that. Resource
requests affect placement but do not cap CPU use.

Tank hosts two Woodpecker runner pods (0.25-core request each) and occasionally
a build or service pod. At inspection, four Woodpecker build/service pods were
on stone and two on tank; individual short-lived builds reached 1.5–2.1 cores
in sparse hourly samples. Woodpecker is a plausible burst amplifier, not the
measured explanation for tank's seven-day baseline. Tank also hosts Garage
gateway and local storage, Immich, Ceph osd.6/osd.10, mon.c, mgr.a, and the
control plane. Ceph and the control plane are not interchangeable placement
targets; move only workloads whose storage and scheduling constraints permit
it. The separate Robbinsdale rightsizing PRs own request/limit edits.

### Drives and Ceph recovery

Tank's SMART exporter reports health `0` for sda and sdb, with 1,905/1,959
reallocated and 736/160 pending sectors respectively. It also reports sdc
health `0` with 1,374 reallocated and 808 pending sectors; the physical mapping
of sdc to a current OSD was not established here. The reported failed osd.12
is absent from `ceph osd tree`. At inspection, all ten remaining OSDs were up
and in, all 114 PGs were `active+clean`, none were remapped, and aggregate Ceph
IO was about 1.8 MiB/s read and 10 MiB/s write. OSD commit latency was 4 ms
for osd.10 and 0 ms for osd.6. Thus **active OSD recovery IO is not the current
CPU cause**. Failed drives remain a durability and future-recovery risk; this
finding does not assume they will be replaced. Ceph still reports
`HEALTH_WARN` for recent daemon/module crashes, not degraded PGs.

The node conditions and node-problem-detector log showed no current pressure
or kernel deadlock. Kubernetes retained no node events for tank and no recent
`FailedCreatePodSandBox` event matching the reported failure. Direct Talos
kubelet/containerd logs could not be retrieved because this workspace has no
active `talosctl` context. The available data therefore cannot rank a specific
kubelet or containerd error as a cause.

## Ranked causes and remedies

1. **Sustained CPU contention — primary.** Seven-day busy CPU p95 11.91/12
   cores and CPU PSI waiting p95 about 79% make routine pod startup and control
   plane work sensitive to bursts. **Safe now:** keep Talos upgrades paused
   until repeated read-only CPU/PSI, node readiness, etcd health, and
   kube-apiserver `/readyz` checks show headroom, then follow the one-node-at-a-
   time control-plane procedure. **Needs restart (HELD):** review placement of
   movable Immich, Garage, monitoring, and Woodpecker workloads and the
   rightsizing PRs together; any scheduling or live manifest change needs its
   own green PR and rollout approval. Moving Ceph or Garage storage without
   checking data placement is not a generic fix.
2. **Endpoint-create burst at tank — immediate mechanism for the 429s.** The
   agent recorded 168 429s with only three parallel creates allowed; current
   six-hour increase is zero. **Safe now:** avoid concurrent build/reconcile
   bursts during the eventual Talos maintenance window and check the 429
   counter before and after. **Needs restart (HELD):** changing runner/job
   scheduling to keep transient builds off the control-plane node is a targeted
   option if further samples show tank-local builds preceding new 429s.
   Changing Cilium limits/configuration is **HELD** and is not recommended from
   these data; it could mask the underlying CPU shortage.
3. **Failed disks — durability risk and possible future IO amplification.**
   Three tank drives report failed SMART health, but Ceph has no current
   recovery or remapping work. **Safe now:** monitor SMART and PG state before
   any upgrade; account for the unavailable osd.12 and the no-replacement plan
   in capacity and failure-domain decisions. **Needs restart (HELD):** any
   OSD/device topology change or Talos reboot should await a separate storage
   risk review.

The most direct practical path to an upgrade is sustained CPU headroom followed
by the prescribed rolling readiness checks. No live change or upgrade was made
for this investigation.

## Reproduce the evidence

Use `tools/kc.sh rb` for `get node tank`, `top nodes`, `get pods -A`, `top pods
-A --containers`, Flux Kustomizations, and Cilium logs. Read Cilium's
`http://192.168.50.51:9962/metrics`; the 429 counter is
`cilium_api_limiter_processed_requests_total{api_call="endpoint-create",return_code="429"}`.
Mimir is `http://10.2.17.251/prometheus/api/v1` with header
`X-Scope-OrgID: talos-robbinsdale`; the CPU/PSI series are
`node_cpu_seconds_total`, `node_pressure_cpu_waiting_seconds_total`, and
`container_cpu_usage_seconds_total`, filtered to `node="tank"` or
`instance="192.168.50.51:9100"`. SMART data are
`smartctl_device_smart_status` and `smartctl_device_attribute` from
`pod="smartctl-exporter-0-wmpmt"`. Read-only Ceph commands were `ceph status`,
`ceph osd tree`, `ceph osd perf`, and `ceph pg stat` through the Rook tools pod.
