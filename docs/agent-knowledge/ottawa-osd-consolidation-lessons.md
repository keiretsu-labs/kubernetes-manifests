# Ottawa OSD consolidation (#3614): lessons from asuka

Observed 2026-10-11 while running #3614 steps 1–4 on asuka.

## Spec change restarts OSDs and re-marks them in
Merging Step 0.2 (#3615) made Rook's op-osd reconcile restart the host's OSD
pods. Restarted OSDs came back `in`, undoing an earlier `ceph osd out`. Wait for
`op-osd: finished running OSDs` in the operator log before `ceph osd out`, and
re-check REWEIGHT 0 in `ceph osd tree` a few minutes into the drain.

## Purge triggers a second rebalance
Purging the drained OSDs removes the host's CRUSH weight, which remaps ~14% of
objects among the remaining hosts (misplaced, not degraded). Wait for
`active+clean` again before zapping.

## `ceph-volume lvm zap` can hang on udev; never run it twice
In the privileged pod, `ceph-volume lvm zap … --destroy` hung in `lvremove`
(blocked on a pipe, waiting for udev sync) with no error. A remote-exec wrapper
that auto-retried on a dropped session started a **second** concurrent zap on the
same drive. Both hung, leaving the VG half-removed.

Fix that worked: kill both `ceph-volume`/`lvremove` processes, then run the zap
**once**, detached, with output logged:

    DM_DISABLE_UDEV=1 nohup ceph-volume lvm zap /dev/disk/by-id/<samsung-by-id> --destroy > /tmp/zap.log 2>&1 &

Then poll the log. It completed in seconds. Verify `pvs`/`vgs`/`lvs`/`dmsetup ls`
are empty and `lsblk` shows the drive with no children. Never wrap non-idempotent
commands in an auto-retrying exec helper.

## `flux resume` does not restore a hand-scaled operator
Step 4 says scale the operator back to 1 and then run `flux resume hr rook-ceph`.
If you rely only on `flux resume`, the operator stays at 0: Helm sees no
chart/values change, and drift detection is off on this HelmRelease. To make Flux
restore it from Git with no hand scaling, run
`flux reconcile hr rook-ceph -n rook-ceph --force`.
