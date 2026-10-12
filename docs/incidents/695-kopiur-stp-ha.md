# #695 — StP HA capture via kopiur (Direct)

**Status (2026-10-11 UTC):** Scheduled Kopiur capture recovered after the
mover scheduling fix in km#3585. A restore drill remains outstanding.
VolSync is out (Raj). Velero was retired in the 2026-09-16 Kopiur cutover.

## Mover scheduling failure and recovery

The St. Petersburg `home-assistant/homeassistant-config` PVC is still Bound to
a local-path hostPath PV on `orin-0`. Its Kopiur `SnapshotPolicy` explicitly
selects that PVC with `copyMethod: Direct`, so the old Velero silent-skip
failure mode is no longer present. Before the scheduling fix, the latest
successful scheduled Snapshot ended on 2026-09-27 at 12:14 UTC; the most
recent successful copy overall was a manual Snapshot ending on 2026-09-28
at 12:37 UTC (208 new files, 36,071,304 bytes). Daily Snapshots through
2026-10-10 then failed before copying data. The 2026-10-10 Snapshot's
`Ready=False` condition reports `MoverPodWedged`: `orin-0` has insufficient
schedulable memory, while the other two nodes do not match the mover's source-node
affinity. All three nodes are `Ready`; readiness does not establish mover
headroom.

km#3585 reduced the mover's memory request from 128Mi to 32Mi. Flux deployed
it before the next scheduled run. St. Petersburg Snapshot
`homeassistant-config-20261011121217` reached `Succeeded` and `Ready=True` at
2026-10-11 12:12:45 UTC, with `status.stats.filesNew: 249` and
`sizeBytes: 8757988`. The live policy records a last successful Snapshot at
12:12:31 UTC. This confirms a nonempty scheduled capture after the fix. No
Restore object or byte comparison has been verified, so recoverability is
still unproven.

During the failure, Ottawa Alertmanager had three critical alerts for this
one policy:
`KopiurSnapshotFailureState` (10 consecutive failures),
`KopiurSnapshotFailed` (latest terminal result), and
`KopiurSnapshotSuccessStale` (last success older than 24 hours). On 2026-10-11
after the successful capture, the Ottawa Alertmanager API returned none of
these alerts for `homeassistant-config`; Mimir's `ALERTS` query returned no
firing instances for these alert names. Alertmanager had 32 active instances
total, compared with 35 on 2026-10-09 and 61 reported in corp/bhaiya#686 in
September. The historical Velero PVB alert source in #686 is gone because
Velero CRDs are absent in Ottawa and St. Petersburg. The broader alert-fatigue
concern in #686 cannot be judged resolved from the count alone. For #695, the
silent hostPath skip is replaced by an explicit Kopiur policy and the current
scheduled capture works; the restore acceptance check remains open.

Read-only triage from this repository:

```console
tools/kc.sh sp -n home-assistant get snapshotpolicy homeassistant-config -o yaml
tools/kc.sh sp -n home-assistant get snapshots -o wide
tools/kc.sh sp -n home-assistant describe snapshot homeassistant-config-20261011121217
tools/kc.sh sp -n home-assistant get pod homeassistant-0 -o wide
tools/kc.sh sp describe node orin-0
```

On each new Snapshot, inspect `Ready`, `Stalled`, and the file/byte stats; a
reconciled `SnapshotPolicy` is not proof of a completed copy. If scheduling
fails again, inspect node allocated requests and live memory pressure.
Preserve the Direct mover's source colocation: the PV is bound to `orin-0`,
so removing node affinity would not make the hostPath data available on a
Spark node. A restore into a new empty PVC and byte comparison of critical
Home Assistant config paths is still required for end-to-end acceptance.

## Constraints encoded in manifests

| # | Constraint | Where |
|---|------------|--------|
| 1 | `copyMethod: Direct` **explicit** | `SnapshotPolicy` |
| 2 | Source `readOnly: true` | `SnapshotPolicy.sources[]` |
| 3 | Dedicated bucket `kopiur-stpetersburg` + own Kopia password | GarageBucket + ESO Password |
| 4 | `maintenance.enabled: false` (km#2767 RAW) | `Repository` |
| 5 | Chart `0.10.7` + image digests pinned | `HelmRelease` |
| 6 | StP only | `kubernetes/apps/stpetersburg/kopiur` |

## Prior scheduling constraint: invalid `SnapshotPolicy.spec.mover.tolerations`

Installed CRD: `spec.mover` allows only `cache`, `inheritSecurityContextFrom`,
`podSecurityContext`, `privilegedMode`, `resources`, `securityContext`,
`ttlSecondsAfterFinished` — **no tolerations**.

How Direct movers still schedule onto tainted orin-0:

1. **Not** HelmRelease root `tolerations` — chart model: root = controller only.
2. **Not** `inheritSecurityContextFrom` — security only; HA also pins no `runAsUser`.
3. **Yes:** `Repository.moverDefaults.sourceColocation: Auto` (default) pins the
   mover to the RWO holder node and **unions the holder pod's tolerations**.
   `homeassistant-0` already has `node-role.kubernetes.io/control-plane` Exists
   NoSchedule.
4. **Yes:** `Repository.moverDefaults.tolerations` (CRD-valid) as explicit base.

Root read access: `securityContext.runAsUser: 0` + `runAsNonRoot: false` **and**
`privilegedMode: true` (namespace-gated; preserve ownership on restore). Mount
stays `readOnly: true`.

## Acceptance

1. **Met on 2026-10-11:** a `Snapshot` for `homeassistant-config` reaches
   `Succeeded` with nonzero file and byte stats (zero files can indicate a
   false success).
2. **Outstanding:** `Restore` into a new empty PVC; byte-compare critical
   paths (`configuration.yaml`, `home-assistant_v2.db`, `.storage/`) against
   the source.

“Schedule exists” is **not** acceptance.

## License

kopiur is **AGPL-3.0-only**.
