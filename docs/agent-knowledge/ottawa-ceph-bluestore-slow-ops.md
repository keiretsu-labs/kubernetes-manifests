# Ottawa Rook-Ceph BLUESTORE_SLOW_OP_ALERT

Read-only runbook for keiretsu-labs/kubernetes-manifests#2212. Do not mute
the health check, raise `bluestore_slow_ops_warn_threshold`, run `ceph osd
unset`, or `ceph tell` mutations. Hardware replacement and OSD restart are
staffed maintenance, not this procedure.

## What the warning is

`BLUESTORE_SLOW_OP_ALERT` means at least one BlueStore KV commit on an OSD
exceeded `bluestore_kv_sync_util_logging_s` (10s) and the count stayed above
`bluestore_slow_ops_warn_threshold` (1) inside
`bluestore_slow_ops_warn_lifetime` (86400s). The health flag therefore stays
`HEALTH_WARN` for up to 24 hours after the last slow commit.

That latch is why `ceph_health_status == 1` is not a page by itself. The
actionable signals are:

| Signal | Meaning |
|---|---|
| `ceph_healthcheck_slow_ops > 0` | currently blocked client ops (`CephSlowOps`) |
| `increase(ceph_bluestore_slow_committed_kv_count[15m]) >= 20` | a live BlueStore KV stall (`CephBlueStoreSlowKV`) |
| `ceph health detail` listing `osd.N observed slow operation indications` | latched history, possibly still current |

`ceph_health_detail{type="BLUESTORE_SLOW_OP_ALERT"}` is not a usable series.
Use the toolbox, not that selector.

## Read-only confirmation

```sh
tools/kc.sh ot -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
tools/kc.sh ot -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail
tools/kc.sh ot -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
tools/kc.sh ot -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd perf
tools/kc.sh ot -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd df
```

For each alerting OSD:

```sh
tools/kc.sh ot -n rook-ceph exec deploy/rook-ceph-tools -- ceph tell osd.N dump_historic_slow_ops
```

Correlate with Mimir tenant `talos-ottawa`:

```
increase(ceph_bluestore_slow_committed_kv_count[15m])
increase(ceph_bluestore_slow_committed_kv_count[24h])
ceph_healthcheck_slow_ops
```

## Ottawa OSD map (osdsPerDevice: 4 except shiro)

| Host | OSDs | Device class | Shared device (2026-09 mapping) |
|---|---|---|---|
| `asuka` | 1, 4, 7, 10 | ssd | Samsung 990 EVO Plus 4TB `S7U8NJ0Y215173Y` |
| `kaji` | 2, 5, 8, 11 | ssd | Samsung 990 EVO Plus 4TB `S7U8NJ0Y215081F` |
| `rei` | 0, 3, 6, 9 | ssd | Samsung 990 EVO Plus 4TB `S7U8NJ0Y215086Z` |
| `shiro` | 12, 13 | nvme | WD SN770 2TB / Kingston 1TB (one OSD each) |

Re-check `ceph osd metadata` / `ceph_disk_occupation` before acting on this
table. Four OSDs alerting on one host is one physical SSD, not four drives.

## How to read a finding

- All 14 OSDs up+in, PGs `active+clean`, and `ceph_healthcheck_slow_ops=0`
  means the cluster is serving. The warning can still be a recent 10–17s
  stall that clients felt.
- Historic ops with `osd_op(mds.*)` are CephFS metadata (MDS). Ops with
  `client.*` are RBD/CephFS data clients; `client_addr` is a node IP on
  `192.168.169.0/24`.
- A burst that hits every host in the same minute is cluster-wide I/O or
  recovery/scrub pressure, not a single failed SSD. A burst confined to
  `asuka` or `kaji` still implicates that node's shared Samsung 990 EVO Plus.
- Capacity, SMART media errors, and `rei` running the same drive model have
  already been insufficient as sole explanations. Do not treat a new
  `HEALTH_WARN` as unknown: dump historic ops first.

## What not to do

- Do not `ceph health mute BLUESTORE_SLOW_OP_ALERT`.
- Do not raise `bluestore_slow_ops_warn_threshold` or shorten the lifetime
  to make `HEALTH_OK`.
- Do not restart OSDs, compact BlueStore, or start a Rook/Ceph version
  rollout from this warning alone. Ottawa Rook/Ceph upgrades remain a
  staffed maintenance decision while recurrence is active.
- Do not infer this from `ceph_health_status` without `ceph health detail`.
