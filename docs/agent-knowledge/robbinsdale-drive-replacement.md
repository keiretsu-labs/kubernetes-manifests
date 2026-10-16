# Robbinsdale tank drive retirement and stone thermal runbook

This is a staffed procedure. Every state-changing step below is **HELD for
CoS**. Do not execute it from a read-only assessment lane. Recheck the live
device-to-OSD mapping immediately before any action; Linux `sdX` names can
change after a reboot.

## Current state and capacity (2026-10-11 14:56 UTC)

Read-only commands through `tools/kc.sh rb -n rook-ceph exec
deploy/rook-ceph-tools -- ceph …` showed 10/10 OSDs up and in, 114/114 PGs
`active+clean`, no remapped PGs, and `HEALTH_WARN` only for two old daemon and
two old mgr-module crashes. `osd.2` and `osd.12` are **absent** from the
current OSD tree, so this is already the observed capacity **after** both were
removed. The live CephCluster and
`kubernetes/apps/base/rook-ceph/rook-ceph-robbinsdale/config/cluster.yaml`
both select only `nvme*` and `sdd` on tank. No new OSD can be provisioned
from tank's `sda`, `sdb`, or `sdc` by this spec.

| Tank device | Serial from 2026-09-25 CoS inspection | OSD then | OSD now |
| --- | --- | --- | --- |
| `sda` | `P8GN563X` | none; stale BlueStore label claimed `osd.11` | none; live `osd.11` is stone NVMe |
| `sdb` | `P8GUX83P` | `osd.12`, out/noin, zero PGs | absent |
| `sdc` | `P8J7YNNP` | `osd.2`, out/noin, zero PGs | absent |
| `sdd` | verify serial again | `osd.6` | `osd.6`, healthy WDC HDD; preserve |
| `nvme0n1` | verify serial again | `osd.10` | `osd.10`; preserve |

The 2026-09-25 CoS record in `/workspace/notes/ops-lanes-2026-09-25.md`
documents the actual one-at-a-time drain: `osd out 2` finished in under
30 seconds (189 MiB raw), then `osd out 12` in about 50 seconds (170 MiB
raw), followed by per-OSD `noin`. They were **not purged or wiped then**.
Their later disappearance from the OSD map is observed; the exact later
purge/wipe action is not established by Git history. Do not replay an
`osd out` or `purge` command against an absent ID.

Ceph `df detail` now reports 935.05 GiB raw used / 15.46 TiB raw total
(5.90%). The live nearfull, backfillfull, and full ratios in `ceph osd dump`
are 85%, 90%, and 95%. `ceph config get mon mon_osd_*_ratio` returns
`EINVAL` because these ratios are special monitor values; use `osd dump`
for the effective thresholds.

| Pool(s) | Stored logical | Raw used | Reported MAX AVAIL |
| --- | ---: | ---: | ---: |
| `ceph-blockpool-replicated-nvme` | 341.03 GiB | 927.19 GiB | 760.07 GiB |
| `filesystem-metadata` | 0.30 GiB | 0.90 GiB | 3,230.18 GiB |
| `.mgr` | 0.10 GiB | 0.31 GiB | 3,230.18 GiB |
| Other 16 pools combined (CephFS, test, RGW; EC RGW data included) | under 0.01 GiB | 0.015 GiB | per-pool values vary |

`MAX AVAIL` is a CRUSH/replication-limited estimate of additional logical
data, not a promise of usable space at a particular OSD. All 18 replicated
pools have size 3 and min_size 2; the RGW buckets data pool is erasure coded.
The NVMe blockpool uses host failure domain and has exactly one eligible NVMe
OSD on each of tank, stone, and titan (`10/11/5`). Host-domain pools still
have three eligible hosts; the other pools' PGs are currently clean. There is
enough capacity for today's data, but **no spare host failure domain** for
size-3 placement, and
tank's `osd.6` is now its only HDD OSD. A tank outage can leave host-domain
PGs degraded or unavailable until it returns; do not combine retirement with
a mon move, node drain, Talos upgrade, or OSD restart.

| Host / OSD / class | Used / size (GiB) | Fill | Headroom to 85% (GiB) |
| --- | ---: | ---: | ---: |
| tank `6` HDD | 0.45 / 3,726 | 0.01% | 3,166 |
| tank `10` NVMe | 315 / 931 | 33.80% | 476 |
| stone `1` HDD | 0.26 / 3,726 | 0.01% | 3,166 |
| stone `4` SSD | 0.05 / 232 | 0.02% | 197 |
| stone `11` NVMe | 315 / 1,863 | 16.92% | 1,268 |
| titan `9` HDD | 0.27 / 3,726 | 0.01% | 3,166 |
| titan `5` NVMe | 303 / 931 | 32.60% | 488 |
| titan `0/3/7` SSD | each under 0.17 / 232 | at most 0.07% | at least 197 each |

These are current `ceph osd df tree` measurements, rounded. No OSD is close
to nearfull or backfillfull. Since `osd.2` and `osd.12` are already gone and
all PGs are clean, **incremental backfill for retiring these IDs is zero now**.
For the earlier drain, the 189 + 170 MiB raw was an upper-bound planning
quantity for reads from the two old tank drives, with replacement writes
spread by CRUSH. The actual operations took under a minute each, but that
history cannot predict a future drain under a different load. Budget at least
15–30 minutes of staffed observation per OSD, and gate on PG state rather
than a timer. Tank `osd.6` has flapped under CPU pressure before; keep
competing IO and pod rescheduling off tank during any storage maintenance.

## CoS-only retirement sequence (conditional)

The present live state calls for **verification and, if still needed, disk
label cleanup**, not a new drain. The sequence below applies only if fresh
inspection finds a target OSD still in the map, or if the exact disk retains
stale Ceph metadata. Commands marked HELD require CoS to authorize and run
them. Do one disk completely, then repeat all gates before the next.

0. **Stream-gate check (media pause; advisory until the gate controller
   lands).** Before any drain, restart, or host reboot step, confirm media
   serving is idle or the gate has timed out: read the ConfigMap
   `media/stream-gate-robbinsdale` key `ready` (expect `"true"`) —
   `tools/kc.sh rb -n media get cm stream-gate-robbinsdale -o
   jsonpath='{.data.ready}'`. Once the stream-gate controller exists
   (design doc `docs/proposals/tracearr-stream-gate-and-media-bots.md`,
   "Ceph maintenance" consumer), the same signal is served as
   `GET .../ready?scope=ceph`; that endpoint is authoritative and the
   ConfigMap is its projection. `ready="false"` means active streams are
   holding the gate: schedule around them or wait for the gate's MAX_WAIT
   fail-open (6h) rather than muting anything. This mirrors the tuppr
   health check merged in #3734 and must not replace the PG-state gates
   in steps 1 and 3.

1. **Read-only preflight.** Finish any pending monitor move first. Verify
   `ceph -s`, `ceph health detail`, `ceph pg stat`, `ceph osd tree`,
   `ceph osd df tree`, `ceph df detail`, the pool size/min_size and ratios,
   and three mons in quorum on distinct hosts. At this snapshot the mon pods
   were `c` on tank, `h` on stone, `j` on titan; confirm whether a separate
   monitor move remains pending.
   Require all 114 PGs `active+clean`, no recovery/backfill/degraded/misplaced
   PGs, and stable tank `osd.6/10` and mon for at least an hour. Old crash
   reports alone may remain as `HEALTH_WARN`; investigate any new warning.
   Recheck Talos disk serial, WWN, size and node before every wipe. In
   particular, never treat `sda`'s stale `osd.11` label as the live stone
   `osd.11`. Confirm the live and GitOps CephCluster selections exclude
   the target disk. If either selects it, **HELD**: first make a reviewed
   GitOps PR to remove that device from
   `kubernetes/apps/base/rook-ceph/rook-ceph-robbinsdale/config/cluster.yaml`,
   verify with `tools/check.sh talos-robbinsdale`, merge under the rollout
   policy, and wait for Flux reconciliation. Do not live-patch the CephCluster.
2. **HELD — drain only if the target ID exists and is in.** For the sdb
   OSD, run `ceph osd out 12` in the toolbox. The sda disk has **no live
   OSD**, so it has no `osd out` step. If an OSD is already out, skip this
   command. With `mon_osd_auto_mark_in=true`, CoS may keep a per-OSD
   `noin` during a crash-prone drain, as done on 2026-09-25; do not set a
   cluster-wide `noin`.
3. **Read-only recovery gate.** Re-run status, health, PG stat/tree/df and
   `ceph osd safe-to-destroy 12` (or the freshly verified ID). Wait until
   every PG is `active+clean`, no recovery remains, the target has zero
   PGs, and `safe-to-destroy` succeeds. Expect temporary `OSD_OUT`,
   degraded/remapped/recovering or `OSD_FLAGS` warnings. Stop on any
   inactive PG, new mon-quorum loss, tank `osd.6/10` flap, rising client
   errors, or an OSD reaching 85%/90%; do not continue to purge or wipe.
4. **HELD — purge only a verified, safe, still-present OSD.** CoS runs
   `ceph osd purge 12 --yes-i-really-mean-it` only after the gate and after
   verifying that ID still belongs to the target disk. Rook's
   `removeOSDsIfOutAndSafeToRemove: true` may remove a deployment without
   purging the Ceph identity. If the ID is already absent, skip purge. Check
   that its OSD Deployment and map entry are gone before disk cleanup.
5. **HELD — wipe only the exact retired device.** On tank, recheck the
   serial/WWN against the table and live Talos inventory, ensure the device
   is not the boot disk or `osd.6/10`, then have CoS use the authenticated
   Talos context and `talosctl -n <verified-tank-node> wipe disk sdb
   --method FAST` (for `P8GUX83P`) or `… wipe disk sda --method FAST`
   (for `P8GN563X`). Talos refuses a device in use; resolve that condition
   rather than forcing it. A FAST wipe removes metadata, not sensitive data
   sanitization. Recheck that the intended disk is blank and `sdd` and
   `nvme0n1` remain intact.
6. **Final GitOps and health gate.** The current CephCluster tank
   `nodes.devices` list already excludes sda/sdb/sdc; confirm that remains
   true in Git and live after cleanup. Verify all expected survivor OSDs are
   up/in, all PGs are clean (114 at this snapshot), and their IDs are
   unchanged before moving to the second disk.

**Abort and rollback:** Before purge/wipe, CoS can stop work and, if the disk
is healthy and still hosts a valid OSD, run `ceph osd in <verified-id>`
(HELD), remove only that ID's temporary `noin` (HELD), and wait for clean
PGs. A failing disk should stay out while the root cause is fixed; do not
reintroduce it merely to clear a warning. Purge and wipe are irreversible for
that identity. Afterwards recovery means provisioning a *verified healthy*
replacement via GitOps or restoring from backup, with a new OSD identity and
another full health gate. Do not try to recreate the stale tank `osd.11`
identity. If any gate fails, leave the next disk untouched and escalate.

## Separate stone nvme0 risk

`stone/nvme0` is not a Ceph OSD. It is the host `/var` device. The current
Garage node-local member mounts:

```text
/var/local-path-provisioner/garage-node-local/robbinsdale-700/metadata
/var/local-path-provisioner/garage-node-local/robbinsdale-700/data
```

The stone Garage gateway uses an SMB PVC, not nvme0. `/var` also holds node
runtime state such as kubelet, containerd, logs, and host-mounted daemon state;
those are not Ceph-replicated data.

The 2026-09-09 inspection found `nvme0` SMART health passing but temperature
74°C against a 65°C alert threshold. Treat cooling and host-local storage
maintenance as a separate work item. Recheck current temperature and Garage
layout before any host maintenance.
