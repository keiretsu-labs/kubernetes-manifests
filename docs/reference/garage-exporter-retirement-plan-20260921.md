# Garage exporter retirement plan

Status: planning only. This document does not retire, resize, adopt, or delete
any Garage bucket, GarageBucket, exporter, or workspace resource.

## What #3123 delivered

PR #3123 (`chore(garage): simplify operator monitoring delivery`) landed the
garage-operator 0.7.11 pin, removed the Service and ServiceMonitor selector
workarounds now supplied by the chart, kept the version-scoped
`GarageNodeDisconnected` aggregation patch, enabled the chart ServiceMonitor,
quota rules, and dashboard, and retargeted the local Grafana bucket panels to
operator metrics. It deliberately left the exporter deployed.

The post-merge live signal is present: Mimir-Ottawa reports 102
`garage_operator_bucket_*` series for `job="garage-operator-metrics"`.

## Homepage decision

The homepage is an additional exporter consumer, not just a Grafana consumer:

- `kubernetes/apps/base/home/home/homepage/garage.html:466-467` documents
  `sum(garage_bucket_bytes)` and `sum(garage_bucket_objects)`.
- `kubernetes/apps/base/home/home/homepage/server.py:125-126` executes those
  same queries for the Garage tiles.

Do not port those queries to operator metrics in this PR. At the read-only
audit on 2026-09-21, operator-only storage covered the CR-backed buckets but
omitted the exporter-only data. The COS audit observed:

| Query | Bytes |
| --- | ---: |
| `sum(garage_bucket_bytes)` | 894,455,547,400 |
| `sum(garage_operator_bucket_size_bytes)` | 824,224,390,578 |
| Difference | 70,231,156,822 |

A recheck at Mimir sample time `2026-09-21T14:50:49Z` observed exporter bytes
of `894,522,781,012`, operator bytes of `824,224,390,578`, and a difference of
`70,298,390,434`. The changing exporter total is expected as buckets receive
data; it does not make the missing-data problem safe to ignore.

Replacing the homepage queries with operator-only queries would silently
under-report roughly 70 GB of stored data. The exporter remains the faithful
source for those aggregate tiles until every retained bucket is represented by
operator metrics or an explicitly accepted alternate source.

## Dashboard deletion patches

Keep the `GrafanaDashboard` delete patches in:

- `kubernetes/apps/robbinsdale/garage/garage.yaml:21-31`
- `kubernetes/apps/stpetersburg/garage/garage.yaml:21-31`

Commit `d1f3a565` introduced these as the site-specific
`fix(monitoring): prune dashboards without Grafana` behavior. A live read-only
check found no Grafana resource, Grafana deployment, or GrafanaDashboard object
in either Robbinsdale or St. Petersburg; only the Grafana CRDs are installed.
Ottawa does have the Grafana instance and consumes the local
`GrafanaDashboard/garage-grafana-dashboard` from
`kubernetes/apps/base/garage/garage`.

The 0.7.11 chart's `grafanaDashboard.enabled` surface is not a replacement for
these patches: it renders a ConfigMap named
`garage-operator-garage-dashboard` in `garage-operator-system`, while the
site patches delete the local `GrafanaDashboard` in the `garage` Flux
Kustomization. The objects, namespaces, and ownership boundaries differ. No
site patch is removed or inverted here.

## Inventory and exact set difference

The exporter query returned 25 unique `garage_bucket_bytes{job="garage-exporter"}`
bucket labels. Ottawa has 18 GarageBucket objects, but only 17 unique
`spec.globalAlias` values because both `firefly/firefly-postgres` and
`garage/firefly-postgres` declare the same alias. The exact Ottawa-local set
difference is consequently eight buckets, not seven:

| Exporter bucket | Bytes at recheck | Objects at recheck | CR ownership / disposition |
| --- | ---: | ---: | --- |
| `kopiur-robbinsdale` | 60,906,084,885 | 4,699 | Already adopted by `garage/kopiur-robbinsdale` in Robbinsdale; do not create an Ottawa duplicate. |
| `kopiur-stpetersburg` | 178,378,730 | 320 | Already adopted by `garage/kopiur-stpetersburg` in St. Petersburg; do not create an Ottawa duplicate. |
| `raj-assistant-web` | 717,947 | 13 | Adopt into a GarageBucket CR owned by the CDN/site consumer, preserving its website/key contract. |
| `ws-hermes-agent-wats-kartik` | 13,134 | 2 | Accept as unmanaged until the workspace/site owner is identified; retain in a narrowed exporter set. |
| `ws-hermes-agent-wats-site` | 11,421 | 2 | Accept as unmanaged until the workspace/site owner is identified; retain in a narrowed exporter set. |
| `ws-raj-trades-hello` | 911 | 1 | Accept as unmanaged until the workspace/site owner is identified; retain in a narrowed exporter set. |
| `ws-raj-trades-site` | 201,113 | 5 | Accept as unmanaged until the workspace/site owner is identified; retain in a narrowed exporter set. |
| `ws-raj-trades-www` | 170,622 | 2 | Accept as unmanaged until the workspace/site owner is identified; retain in a narrowed exporter set. |

The two Kopiur buckets have live GarageBucket CRs in their sibling clusters,
so they are not globally unmanaged. The six remaining buckets have no
GarageBucket CR in Ottawa, Robbinsdale, or St. Petersburg at this audit. The
requested “seven CR-less buckets” is therefore a cardinality subtraction
(`25 - 18`), not the exact set difference; the duplicate Ottawa alias makes
the local set difference eight and the global unmanaged set six. No bucket is
omitted from this plan.

The `raj-assistant-web` repository reference is in the CDN-site configuration.
No repository owner reference was found for the five `ws-*` buckets. Their
small size does not prove that they are disposable; the plan keeps them
observable and unmanaged until an owner confirms adoption or deliberate
retention.

## Retirement gate

The exporter cannot be retired until all of the following are true:

1. The homepage either continues to use the exporter or has a tested union
   query that includes every retained bucket without double-counting the CR
   and exporter views.
2. `raj-assistant-web` is adopted into a CR with its website and key behavior
   verified.
3. Each `ws-*` bucket is either adopted into a CR with an identified owner or
   explicitly accepted as unmanaged. An accepted-unmanaged bucket remains in
   a deliberately narrowed exporter allowlist and therefore continues to
   block exporter retirement unless an alternate complete monitoring source
   is delivered.
4. The two sibling-cluster Kopiur buckets remain covered by their existing
   CRs and are not replaced by duplicate Ottawa declarations.

Only after no retained bucket depends on the exporter should a separate PR
remove the Ottawa `garage-exporter` Flux Kustomization and its
Deployment, Service, and ServiceMonitor. This PR makes no live or GitOps
retirement change.
