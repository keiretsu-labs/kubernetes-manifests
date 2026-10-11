# Zero-file Firefly and Tracearr snapshots, 2026-10-11

Read-only checks on 2026-10-11 compared the latest successful Kopiur Snapshot,
its resolved source, and the running application's PVC mount. These Snapshots
accurately describe empty application directories; they are not evidence of
protected upload or backup files. Each mount is also unwritable by the running
application user, so the empty directories cannot be treated as a harmless
exception to backup coverage.

| Cluster | Application mount and PVC | Latest successful Snapshot | Snapshot stats | Live application data |
| --- | --- | --- | --- | --- |
| Ottawa | Firefly `/var/www/html/storage/upload`, `firefly/firefly-upload` | `firefly-uploads-20261011020533` | 0 new files, 0 bytes | Only root-owned `lost+found`; 0 visible regular files. UID/GID 33 cannot write the root-owned 0755 mount. |
| Ottawa | Tracearr `/data/backup`, `media/tracearr-backup` | `tracearr-backup-20261011030741` | 0 new files, 0 bytes | Only root-owned `lost+found`; 0 visible regular files. UID 1001, GID 65533 cannot write the root-owned 0755 mount. |
| Robbinsdale | Tracearr `/data/backup`, `media/tracearr-backup` | `tracearr-backup-20261011030016` | 0 new files, 0 bytes | Only root-owned `lost+found`; 0 visible regular files. UID 1001, GID 65533 cannot write the root-owned 0755 mount. |

The three live SnapshotPolicies select those exact PVCs with `readOnly: true`.
Each Snapshot reports that PVC in `status.resolved.sources`, uses the expected
cluster repository, and reports a ready staged source. The Git-managed app
mounts also use those claims. There is no evidence here of a wrong Kopiur PVC,
an exclude rule, or a mover path mismatch. Directory `du` output includes ext4
directory metadata (`20,480` bytes for each Tracearr mount) and reports
permission denied for `lost+found`; it does not represent protected file data.

Ottawa Tracearr had about 198 MiB and 9,853 files under its separate
`/data/tracearr/image-cache` directory, which is not mounted from the backup
PVC. That directory is an image cache, not evidence that the `/data/backup`
source contains backup files. The Firefly `storage/app` directory had no files.

The deployment change sets each pod's `fsGroup` to its application's group and
uses `OnRootMismatch` so kubelet can make the PVC root writable on the next
pod start. This changes running workloads when Flux applies it. After rollout,
verify `test -w` as the application user, then confirm that a real upload or
Tracearr backup produces files on the PVC and a later Snapshot captures them.
Do not exempt these policies from zero-file coverage solely because the current
PVCs are empty. A successful Snapshot is not a restore test.
