# PriorityClass proliferation audit (2026-10-18)

Findings-only census of every PriorityClass, its preemption behaviour, and its
consumers; drift check against docs. No config change.

## The custom set (4 — single source `kube-system/priority-classes/app/priorityclasses.yaml`)

| Class | Value | preemptionPolicy | globalDefault | Declared consumers |
|---|---|---|---|---|
| `infra-critical` | 1000000000 | PreemptLowerPriority | false | tailscale operator helmrelease; cert-manager webhook; external-secrets; fluent-bit; gatus ott+rb; home-assistant statefulset; garage data pods (`garagecluster.yaml:158`) |
| `ai-inference` | 900000000 | PreemptLowerPriority | false | ai model-serving TP ranks ×2 (`model-serving.yaml:332,537`, spark-0 pinned) |
| `infra-high` | 800000000 | PreemptLowerPriority | false | kube-prometheus-stack ×5 (operator/admission webhook, prometheus agent, alertmanager, node-exporter); tailscale ProxyClass `common` ×4; envoy-gateway helmrelease; k8gb controller (strategic patch) + coredns; garage gateways (`garagecluster.yaml:183`); home gateway envoyproxies ×3 |
| `infra-default` | 500000000 | PreemptLowerPriority | false | vpa recommender only (`vpa/helmrelease.yaml:37`) |

None is `globalDefault` — matches architecture.md's priority-classes table
verbatim (values 1e9/8e8/5e8 + the doc's three rows; `ai-inference` is
documented in the ai section, not the table — see D2).

## Built-ins in use (not customizable, census only)

`system-node-critical` ×16 (Cilium agent-adjacent: node-local-dns, multus
patch, generic-device-plugin, descheduler cronjobs, cni-dhcp; node-health
npd/nrr; kata tracee DS; local-path-provisioner; rook mon+osd via
`priorityClassNames` (identical ott/rb: mon/osd node-critical, mgr
cluster-critical); rbd-device-observer; rdma-shared-dp sp) and
`system-cluster-critical` ×6 (rook mgr/filesystem, csi-secrets-store, descheduler).
No `priority:` numeric fields outside the CRDs' schema blocks
(agent-sandbox raw CRD); no chart-default `rook-ceph-default-priority-class`
(any of the `#all:` lines is commented).

## Drift / findings

| # | severity | observation |
|---|---|---|
| D1 | Info | **No proliferation**: exactly 4 custom classes, one defining file, deployed ahead of consumers via the kube-system overlay with the standalone-app rationale documented in-file. Zero app-local PriorityClass objects; zero chart-injected classes (rook `#all:` commented, k8gb patched not duplicated). |
| D2 | Low-cosmetic | `ai-inference` (900M) is missing from the architecture.md priority table (only 3 rows) though its consumer section documents the class implicitly. One-row doc gap; harmless — value ordering correct (critical 1e9 > ai 9e8 > high 8e8 > default 5e8). |
| D3 | Info | All four are `PreemptLowerPriority`; no `Never` preemption anywhere. Given every consumer is platform infra, correct; a `Never` class would only matter for batch/GPU co-tenancy, which `ai-inference`'s naming already reserves room for. |
| D4 | Info | Consumer drift check: every `priorityClassName:` reference in `kubernetes/apps/` resolves to one of the 4 custom or 2 builtin names (54 refs, 45 files, all three clusters inherit from base). No dangling references; `infra-default` has exactly one consumer (vpa) as designed. |
| D5 | Info | rook `priorityClassNames` identical across ott/rb cluster configs (mon/osd `system-node-critical`, mgr `system-cluster-critical`) — no per-cluster drift; matches architecture.md:1109. |

**Verdict: no-finding requiring action.** D2 is a one-line doc touch-up
folded into the next docs PR, not worth its own lane.

## Re-derive

```sh
git grep -c "kind: PriorityClass" -- kubernetes/   # 4, one file
grep -rn "priorityClassName:" kubernetes/apps/ | awk -F'priorityClassName: *' '{print $2}' | sort | uniq -c
```
