# domain, ingress, and repo restructure — design

2026-06-10. Status: approved direction, pending implementation plan.

## why

Three pain points drove this:

1. **Domain segregation is confusing.** `COMMON_DOMAIN` (keiretsu.top) vs per-cluster
   `CLUSTER_DOMAIN` (killinit.cc / lukehouge.com / rajsingh.info) have different routability,
   different DNS writers, and different cert stories. Contributors must know which variable to
   use, which gateway accepts it, and which of seven external-dns instances will publish it.
   St. Petersburg's cluster domain (rajsingh.info) doubling as a personal domain, hardcoded
   hostnames (`pocket-id.killinit.cc`, `grafana.killinit.cc`, `jellyseerr.rajsingh.info`), and
   the parallel `ts./cdn./s3./agents.keiretsu.top` subzone universe make it worse.
2. **OIDC is tangled.** pocket-id runs once (ottawa) but is referenced three ways
   (`pocket-id.${COMMON_DOMAIN}`, `pocket-id.${CLUSTER_DOMAIN}` — only correct on ottawa by
   accident, and hardcoded `pocket-id.killinit.cc`). Per-app SecurityPolicies are copy-pasted
   ~30-line blocks. One plaintext client secret is committed (code-server).
3. **Contribution friction.** Adding an app means knowing the Flux ks.yaml boilerplate, the
   gateway/domain/DNS coupling, and the variable soup. Big shared Flux Kustomizations mean one
   broken app degrades a whole layer. No PR-time rendering/diff exists.

## decisions (locked)

- **keiretsu.top is primary; all four domains are routable at every location.** Vanity domains
  remain fully supported on any cluster, any tier.
- **pocket-id at literal `https://pocket-id.keiretsu.top` is the single OIDC issuer** for
  browser-facing auth (already GSLB-fronted, ottawa-weighted 100, publicly resolvable). tsidp
  stays a tailnet sandbox; ArgoCD stays on GitHub via Dex.
- **Auth is opt-in, not default.** Exposure tier (ts / private LAN / public) is the primary
  access-control decision; OIDC layers on top only where wanted.
- **The three-gateway model stays** (`ts`, `private`, `public`), unmerged, one EnvoyProxy each.
- **Phased full restructure** to the home-operations 3-cluster shape (joryirving/home-ops
  pattern), migrating namespace-by-namespace. No big-bang cutover.

## target repo layout

```
kubernetes/
├── apps/
│   ├── base/<namespace>/<app>/          # ALL real config, exactly once
│   │   └── helmrelease.yaml, httproute.yaml, kustomization.yaml, ...
│   ├── ottawa/<namespace>/
│   │   ├── kustomization.yaml           # namespace.yaml + list of <app>.yaml
│   │   └── <app>.yaml                   # ~10-line Flux Kustomization → base path
│   ├── robbinsdale/<namespace>/...
│   └── stpetersburg/<namespace>/...
├── components/                          # kustomize components: volsync, postgres,
│                                        # oidc-protect, gatus-check, ...
└── clusters/{ottawa,robbinsdale,stpetersburg}/
    └── apps.yaml                        # flux entrypoint; injects LOCATION; patches
                                         # defaults into all child Kustomizations
tailscale/                               # unchanged (policy.hujson, scripts, cicd)
```

- The `common` tier dissolves: a common app is a base app whose pointer file exists in all
  three cluster trees. Deploy-to-some = pointer exists in some. Removing an app from one
  cluster = delete one ~10-line file.
- Per-app Flux Kustomization gives per-app blast radius, prune, health, and `flux get` status.
- **Variable substitution shrinks to `LOCATION` + `CLUSTER_DOMAIN`** (gateway/cert layer only),
  injected once at the cluster entrypoint, with the `StrictPostBuildSubstitutions` feature gate
  on. Apps write literal hostnames (`jellyfin.keiretsu.top`). `${COMMON_DOMAIN}` and friends die.

## the per-app contract

A contributor adds one directory under `apps/base/<ns>/<app>/` plus one pointer file per target
cluster. Ingress is exactly this:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jellyfin
spec:
  parentRefs:                          # exposure tiers — pick any subset
    - {name: ts, namespace: network}
    - {name: public, namespace: network}
  hostnames: [jellyfin.keiretsu.top]   # any of the 4 domains, any cluster
  rules:
    - backendRefs: [{name: jellyfin, port: 8096}]
```

- Cert: already on the listener (wildcard per domain).
- DNS: follows from parentRefs — `public` → Cloudflare, `private` → UniFi, `ts` → Pi-hole.
- Auth: add `components: [.../components/oidc-protect]` in the app's ks.yaml.
- Multi-cluster/geo-failover: opt-in via a K8GB Gslb + apex CNAME (documented pattern).

## network layer (target)

- Gateways, certs, and external-dns move to a `network` namespace.
- **Every gateway gets wildcard HTTPS listeners for all four domains** (`*.keiretsu.top` +
  bare apex, `*.killinit.cc`, `*.lukehouge.com`, `*.rajsingh.info`). The `cdn./s3./agents./
  ts.keiretsu.top` listeners carry over unchanged, as do TCP/UDP listeners (forgejo SSH 22,
  pihole 53, webrtc 8555, neo4j 7687).
- **One pre-created wildcard Certificate per domain** (4 per cluster), DNS-01 via the existing
  per-domain Cloudflare ClusterIssuers, shared by all three gateways. Replaces today's
  per-purpose cert sprawl.
- The `ts` gateway Service stays on `loadBalancerClass: tailscale` + `tailscale.com/proxy-group:
  common-ingress`, which already provisions a **Tailscale Service VIP** (verified live:
  `ipMode: VIP`, stable `<location>-home-envoy-gateway.keiretsu.ts.net` hostname). Tailnet
  split-DNS (tsddns) already targets `svc:<location>-home-envoy-gateway`. This matches
  Tailscale's official BYOD-with-Gateway-API solution doc.
- Listener hostname semantics (most-specific wins, route∩listener intersection) make the
  overlapping wildcards safe; `NoMatchingListenerHostname` should become impossible for the
  four domains.
- ListenerSet (Gateway API v1.5) noted as the future per-app listener-delegation mechanism but
  explicitly **not adopted** — experimental in Envoy Gateway, policy-attachment gaps.

## dns layer (target)

| Resolver | Zones | Writer | Clients |
|---|---|---|---|
| Cloudflare | all 4 domains (public horizon) | one external-dns per domain (per-account tokens, `gateway==public`) | internet |
| Pi-hole (per cluster) | all 4 domains (tailnet horizon) | ts-external-dns (`external-dns==ts`) | tailnet via split DNS |
| UniFi (per site) | all 4 domains + `*.internal` (LAN horizon) | external-dns-unifi (`external-dns==private`) | LAN |
| K8GB CoreDNS | `cdn.keiretsu.top` (public NS-delegated), `ts.keiretsu.top` (tailnet) | Gslb resources | multi-cluster opt-in |

Changes from today:

- Cloudflare external-dns stays one-instance-per-domain: the vanity domains live in
  different Cloudflare accounts (kb/Luke/Raj) and external-dns takes a single
  CF_API_TOKEN, so the split is a credential boundary. All four instances already run
  on every cluster, so the public horizon already covers all four domains.
- Add all four domains to the Pi-hole and UniFi instances' domain filters.
- The Tailscale DNSConfig nameserver stays: each cluster's CoreDNS forwards the
  `ts.net` zone to it (cilium/config/coredns.yaml) for in-cluster MagicDNS
  resolution. The earlier "orphaned" finding was wrong.
- Keep tsddns (45-min split-DNS sync cron) — it is the right tool, now documented.
- Keep `.internal` static DNSEndpoints under UniFi.
- Same hostname in different horizons is by design (split horizon); per-location TXT ownership
  already disambiguates writers.

Known residual risk: each cluster's Pi-hole only learns its own cluster's routes, so tailnet
split-DNS targeting must map each domain to the right Pi-hole(s). Documented; a deeper fix
(multi-writer or K8GB-backed tailnet horizon for keiretsu.top) is deferred.

## oidc layer (target)

- All issuer references become literal `https://pocket-id.keiretsu.top`. The three current
  spellings and all hardcoded `pocket-id.killinit.cc` references are migrated.
- `components/oidc-protect`: a Kustomize component generating the Envoy Gateway SecurityPolicy
  from `${APP}` + the shared `envoy-gateway` pocket-id client. Protecting an app = one
  `components:` line. (Envoy SecurityPolicy targetSelectors are namespace-scoped, so a
  per-app component beats a central label-selected policy.)
- code-server's plaintext client secret moves to SOPS.

## self-serve + ci

- **flate** (`test` + `diff`) on every PR touching `kubernetes/**`: offline render of all
  HelmReleases + substitution emulation, manifest diff commented on the PR.
- `yaml-language-server: $schema=` headers on app files for editor-time validation.
- Renovate for chart/image bumps (digest-pinned).
- `CONTRIBUTING.md`: the copy-this-directory walkthrough — tier picker, domain picker, auth
  opt-in, multi-cluster opt-in.
- Refreshed template directory demonstrating the full contract.

## migration phases (each independently shippable)

1. **CI first** — flate test+diff wired against the *current* tree, so every later phase has
   render/diff coverage.
2. **Network contract in place** — all-domain listeners + 4 wildcard certs, external-dns
   collapse, TS Service VIP, in the existing `clusters/common` tree and existing `home`
   namespace. No app moves. (The rename to a `network` namespace happens in phase 4 when the
   gateway apps migrate to the new tree; until then routes keep `namespace: home` in
   parentRefs.)
3. **OIDC canonicalization** — issuer URLs, oidc-protect component, secret-to-SOPS.
4. **New tree + migrate** — `kubernetes/` skeleton lands beside `clusters/`; apps move
   namespace-by-namespace in reviewable PRs; old and new Flux entrypoints coexist per cluster.
   COMPLETE 2026-06-11: ~110 apps migrated across all three clusters; old `clusters/*/apps`
   trees fully drained (empty placeholder kustomizations only, pending entrypoint retirement).
   The two-PR adopt/release recipe is documented in `kubernetes/README.md`. Note:
   `StrictPostBuildSubstitutions` is a kustomize-controller feature gate, not
   per-Kustomization — enabling it moves to phase 5, after the old tree fully clears.
5. **Retire** — old tree deleted; README/CLAUDE.md rewritten to the new mental model; stale
   docs (the "COMMON_DOMAIN is not routable" note) corrected.
   IN PROGRESS 2026-06-11: CLAUDE.md rewritten; README.md updated; entrypoint retirement
   + StrictPostBuildSubstitutions gate + home→network namespace rename remaining.

## out of scope

- tailscale/policy.hujson restructuring (separate effort; only touched if a phase needs a
  grant/split-DNS change).
- Replacing K8GB, Pi-hole, or UniFi DNS backends.
- ListenerSet adoption.
- App-level config refactors beyond moving directories and fixing hostnames/issuers.

## reference findings (for implementers)

- Current domain values: `COMMON_DOMAIN=keiretsu.top` (`clusters/common/flux/vars/common-settings.yaml`);
  `CLUSTER_DOMAIN` = killinit.cc / lukehouge.com / rajsingh.info
  (`clusters/talos-*/flux/vars/cluster-settings.yaml:26`).
- Gateways: `clusters/common/apps/home/tailscale-gateway/gateway.yaml` (ts),
  `clusters/common/apps/home/local-gateway/gateway-{public,private}.yaml`.
- external-dns: `.../tailscale-gateway/external-dns.yaml` (pihole),
  `.../local-gateway/external-dns-unifi.yaml`, `clusters/common/apps/cloudflare/app/externaldns-*.yaml`.
- K8GB: `clusters/common/apps/k8gb/` (10 Gslb resources, cnames.yaml apex CNAMEs).
- OIDC references to migrate: code-server (`clusters/common/apps/home/code-server/`),
  hubble-ui, grafana (ottawa), frigate, hermes-group SecurityPolicies; verified-live
  `pocket-id.keiretsu.top` → `pocket-id.cdn.keiretsu.top` → ottawa.
- Orphaned: `clusters/common/apps/tailscale/resources/dnsconfig.yaml` (ts-dns nameserver).
- Hardcoded hostnames to clean: `grafana.killinit.cc` (stpetersburg redirect — intentional,
  keep), `jellyseerr.rajsingh.info` (homer dashboard), `pocket-id.killinit.cc` (hubble/grafana
  SecurityPolicies).
- Patterns imitated: joryirving/home-ops (3-cluster base+pointer layout),
  onedr0p/home-ops (literal domains, minimal substitution), buroa/k8s-gitops (dual
  external-dns, wildcard certs), home-operations/flate (CI).
