# PodSecurity admission coverage

Audit of `pod-security.kubernetes.io/*` labels on every Namespaces object in
the repo, per cluster (main `d78cc03ee`, 2026-10-15). Documentation only; the
held PR proposes `warn: restricted` on the no-label namespaces (see end).

Re-derive with:

```sh
git grep -l "pod-security.kubernetes.io" -- kubernetes/
```

## Posture summary

| enforce level | namespaces (where labelled) |
|---|---|
| `restricted` | kopiur-system (shared ns def + stpetersburg overlay) — full enforce/audit/warn restricted |
| `baseline` | searxng (shared) — enforce only |
| `privileged` | 43 namespace instances: infra & node-touching planes (cilium-adjacent, tailscale*, spegel, NFD, snapshot-controller, envoy-gw, fluent-bit, monitoring, media/garage/home/forgejo/hermes/tinyauth…) |
| *none* | 69 namespace instances — cluster default (empty = no PodSecurity constraint at all) |

56 distinct namespaces across the three clusters; 112 namespace.yaml objects
(some namespaces defined once in `base/`, overridden per-location).

## Full per-namespace state

### No PSA labels (69 instances — enforce/warn inherit nothing)

Ottawa (27): agent-sandbox-system, arc-runners, arc-systems, border0, bot,
cert-manager, cloudflare, cnpg-system, dragonfly-operator-system,
external-secrets, firecrawl, firefly, garage-operator-system, gatus,
homer-operator, hubble-ui, immich, k8gb, lan, open-cluster-management,
open-cluster-management-agent, opencost, system-upgrade, tempvm, vpa-system,
woodpecker, zot

Robbinsdale (21): agent-sandbox-system, arc-runners, arc-systems, cert-manager,
cloudflare, cnpg-system, dragonfly-operator-system, external-secrets,
garage-operator-system, gatus, homer-operator, hubble-ui, immich, k8gb, mimir,
open-cluster-management-agent, speedtest, strimzi, system-upgrade, vpa-system,
woodpecker

St. Petersburg (19): agent-sandbox-system, arc-runners, arc-systems,
cert-manager, cloudflare, cnpg-system, external-secrets, flux-system,
garage-operator-system, gatus, homer-operator, hubble-ui, k8gb, lws-system,
mimir, open-cluster-management-agent, system-upgrade, vpa-system
(+ shared: cliproxy, litellm, teslamate)

### enforce=privileged (43)

Full triple (enforce+audit+warn privileged): auth, forgejo, home (ot/rb),
home-assistant (sp), tailscale-pam.
Enforce-only privileged: envoy-gateway-system, fluent-bit, garage, media, mimir
(ot), monitoring, node-feature-discovery, snapshot-controller, spegel,
tailscale, tailscale-examples, tailscale-system (per cluster as listed above);
shared: ai, keiretsu-top. garage carries `enforce-version: latest`.

### enforce=baseline

searxng (shared) — enforce only, no audit/warn.

### enforce=restricted

kopiur-system — the exemplar: enforce/audit/warn all restricted (shared
definition; stpetersburg re-labels its overlay identically).

## Held proposal: `warn: restricted` everywhere

Adding only

```yaml
pod-security.kubernetes.io/warn: restricted
```

to the 69 no-label instances is non-breaking (warn never blocks) and turns
PodSecurity into a telemetry plane: any workload that would violate restricted
shows up in `kubectl events`/admission warnings without gating deploys. The
39 cluster-infra namespaces (cert-manager, cnpg, external-secrets, system-upgrade,
operator sockets, hostNetwork CNI planes) would warn loudly at first — that is
the point; triage the warnings before ever tightening enforce.

Intentionally **not** proposed here: raising any `enforce` level. enforce
changes are rollout-affecting (pod churn on label change is not automatic, but
a mis-set enforce breaks scheduling) and belong to per-app follow-ups after the
warn telemetry has run for a cycle. `warn: privileged` on already-privileged
namespaces is a no-op and skipped.

Held PR: branch `sec1014/psa-warn-labels` — one label line per affected
namespace.yaml. Not merged from this lane; PSA enforce/warn policy changes stay
open for review per charter.
