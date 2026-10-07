# Workspace-image publication freshness

Source of truth for the intended workspace-image release and its registry
probe is the Bhaiya control-plane scrape (`job="bhaiya"`, `container="bhaiya"`)
in the Ottawa Mimir tenant. Native Mimir rules live in
`kubernetes/apps/base/mimir/mimir-ottawa/rules/bhaiya-workspace-image.yaml`
and are loaded by the hashed `mimir-rules` Job for every tenant.

## Publication (v1 dispatcher)

| Series | Meaning |
| --- | --- |
| `bhaiya_workspace_image_intended_info{image,version}` | Dispatch-authoritative intended tag. Value is always `1`. |
| `bhaiya_workspace_image_registry_probe_status{image,version,status}` | One-hot: `published`, `missing` (HTTP 404), or `probe_error`. |
| `bhaiya_workspace_image_registry_probe_last_success_timestamp_seconds` | Last definitive HTTP response, including 404. |
| `bhaiya_workspace_image_registry_manifest_info{digest}` | Digest when the probe received a published manifest. |

Recording rules (same file, evaluated before the alerts):

- `bhaiya_workspace_image_publication_missing`
- `bhaiya_workspace_image_publication_published`
- `bhaiya_workspace_image_publication_unknown`

`BhaiyaWorkspaceImagePublicationStale` fires only on `missing` for `75m`.
`BhaiyaWorkspaceImagePublicationProbeUnavailable` fires on `probe_error` for
`15m`. A registry outage is unknown and does not page as stale.

## v2 promotion (canary_passed → approved)

`bhaiya_image_release_state{tag,state}` is the one-hot catalog gauge exported
by Bhaiya v2 control (`discovered`, `canary_running`, `canary_passed`,
`approved`, `rejected`, `superseded`, `unknown`). It is not currently scraped
into Mimir (no ServiceMonitor on `bhaiya-v2-control`).

Rules in `bhaiya-v2.yaml`:

- `BhaiyaImageReleaseCanaryPassedNotPromoted`: `canary_passed == 1` for `2h`.
- `BhaiyaImageReleaseApprovedStale`: approved age `> 7d` for `1h`.

Approved age requires a timestamp series that v2 does not export yet:

```
bhaiya_image_release_state_since_seconds{tag,state}
```

Unix seconds when the release last entered `state`. Bounded labels only
(`tag`, `state`, plus scrape `cluster`). Absent timestamps keep the age
alert quiet. Tracked on corp/bhaiya (see the issue linked from km#2646).

Grafana: `Bhaiya / Bhaiya workspace-image freshness`
(`uid: bhaiya-workspace-image`).
