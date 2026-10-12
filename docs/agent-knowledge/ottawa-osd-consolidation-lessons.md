# Ottawa OSD consolidation (#3614): lessons

Ran 2026-10-11 16:55 → 2026-10-12 01:0x CT. asuka → kaji → rei, 4 OSDs per
990 EVO → 1. End state: tree 1/1/1/2 (asuka osd.1, kaji osd.2, rei osd.0,
shiro osd.12+13), 81/81 active+clean, HEALTH_OK, operator 1/1, HR not
suspended, temp recovery keys gone from Git and `ceph config dump`.

PRs: #3615 osdsPerDevice=1, #3618 recovery speed-up, #3621 speed-up revert.

## Per-host loop that worked
1. `ceph osd out <4 ids>`, re-check REWEIGHT 0 (see below).
2. Wait 177/all active+clean and `ceph osd safe-to-destroy <ids>` passes.
3. Suspend HR, operator to 0, stop + `ceph osd purge` each, delete deployments.
4. Wait for the post-purge rebalance (no degraded/undersized/down/inactive).
5. Identify disk by-id (Samsung, not the Kingston boot disk), zap once.
6. Restore operator with `flux reconcile hr rook-ceph -n rook-ceph --force`.
7. New single OSD comes up, backfill, wait clean, next host.

## Spec change restarted OSDs and re-marked them in
#3615 made op-osd restart asuka's OSD pods. Git sets
`mon_osd_auto_mark_in: true` (c551a347e, so tuppr drains release host PDBs),
so the restarted OSDs came back `in` and undid the `ceph osd out`. Caught
~30 min later.
- Merge the spec change, wait for `op-osd: finished running OSDs`, then `out`.
- Re-check REWEIGHT 0 in `ceph osd tree` before and a few minutes into the drain.
- Don't fight c551a347e with a live `noin`; it's there for tuppr.

## Never hand-scale the operator
Hand `kubectl scale --replicas=0` + `flux suspend` was used. `flux resume hr
rook-ceph` applied v1.21.0 but left the operator 0/0: no chart/values change
and drift detection is off on this HR, so Helm never reverts the scale.
- Restore with `flux reconcile hr rook-ceph -n rook-ceph --force`.
- Better: pause through Git, not live scale/suspend.

## Zap hung in lvremove; the SSH helper ran it twice
`ceph-volume lvm zap <by-id> --destroy` hung in `lvremove` (udev sync wait,
no error). The remote-exec helper auto-retried on the dropped session and
started a second concurrent zap on the same disk. VG left half-removed.
- Fix: kill both, then once, detached, logged:
  `DM_DISABLE_UDEV=1 nohup ceph-volume lvm zap /dev/disk/by-id/<samsung> --destroy > /tmp/zap.log 2>&1 &`
  Finished in seconds.
- Verify `pvs`/`vgs`/`lvs`/`dmsetup ls` empty, `lsblk` shows no children.
- No auto-retry for destructive or non-idempotent commands. The helper now
  only retries when asked.

## Recovery speed-up through GitOps, removed through Git + ceph config rm
Raised `osd_max_backfills: 4` and `osd_mclock_override_recovery_settings:
true` via CephCluster config in Git (#3618, d9a98a61d). Removal: revert in Git
(#3621, 0bd48c8ab) **and** `ceph config rm osd <key>` for each; the keys
stay in the mon config db after the revert. Check `ceph config dump` after.

## Autoscaler PG merge looks like recovery restarting
Dropping from 14 to 5 OSDs made the pg_autoscaler merge
ceph-blockpool-replicated (128 → 32). PG total went 177 → 81. During the
merge, misplaced % climbs again and `pg_num`/`pgp_num` step down (e.g. 112/82,
96/68): that's premerge, not a stuck drain.
- `ceph osd pool autoscale-status` and `ceph osd pool ls detail` before
  calling it a regression.
- Wait for the merge to finish before cleanup PRs or the next host.

## rei zapped during the merge; safe-to-destroy was the gate
rei's 4 OSDs were purged and had passed safe-to-destroy, but PGs weren't all
active+clean because the merge was running. Zapped anyway with gate: no
degraded/undersized/down/incomplete/stale/inactive PGs. The disk held no live
OSD, so nothing depended on it. Only relax "all clean" when the OSDs on the
disk are already purged.

## New OSD had no device class
rei's new osd.0 came up with no CLASS (`osd_class_update_on_start=false`).
CRUSH rules are classless, so harmless here. Set it
(`ceph osd crush set-device-class nvme 0`) or check it before any
class-based rule lands.

## No talosconfig: lsblk/vgs/lvs for disk ID
`talosctl get systemdisk` failed (empty talosconfig on the operator box).
Used a privileged hostPID pod in a temp `osd-zap` ns:
`ls -l /dev/disk/by-id`, `lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE`, `pvs`,
`vgs`, `lvs`. Zap target = Samsung 990 EVO with the ceph VG; Kingston boot
disk untouched. Cross-check serial with `ceph osd metadata <id>`
`device_ids`. Delete the ns after.

## GitHub App can't comment on issues
keiretsu-kman-bot lacks `issues:write` (403), so #3614 checklist updates
didn't land. Progress lives in PR bodies; grant the permission or expect no
issue comments.

## tuppr / GitOps
- tuppr is the only upgrade path. Pause with the
  `tuppr.home-operations.com/suspend` annotation in Git, never scale or
  `flux suspend` live.
- Suspend → change → resume as separate small commits.
- Keep tuppr's Ceph health gates. Don't run Talos upgrades during a drain or
  merge.
- Live changes get reverted or made declarative right after; check Git and
  live match.
