# Proposal: one self-hosted DNS server for LAN, cluster and tailnet

Status: **Proposed — held for Raj/Kartik.** Docs only; nothing in this PR
changes infrastructure.

Raj's ask (2026-10-13): run our own DNS server instead of the UniFi /
Pi-hole mix — "Technitium or something … better for everything including the
LAN, less things to manage."

Scope: `killinit.cc`, `keiretsu.top`, `rajsingh.info` and the site-internal
zones. **`lukehouge.com` and `typeo.io` are Luke's; this proposal does not
change how they are served.** Where they appear below it is only to record
that they ride through today's pipelines and must keep working unchanged.

## 1. Current state (from this repo, 2026-10-13)

| Plane | What answers | Fed by | Notes |
|---|---|---|---|
| LAN clients, all 3 sites | UniFi gateway (`LAN_GATEWAY_IP`: Ottawa `192.168.169.1`, Robbinsdale `192.168.50.1`, St. Pete `192.168.73.1`) | DHCP hands out the gateway; gateway's static-DNS table | Gateway is DHCP server, recursive forwarder and "authoritative" for local overrides |
| LAN overrides (split horizon) | UniFi static DNS | `external-dns-unifi` (`kubernetes/apps/base/home/home/local-gateway/external-dns-unifi.yaml`), kashalls UniFi webhook v0.9.0, one per site | `policy: sync`, sources crd + 4 gateway-route kinds + service, `gateway==private`, `logLevel: debug` on both containers, default 1m sync interval. Domain filters: keiretsu.top, killinit.cc, rajsingh.info, lukehouge.com, `*.internal`. Cannot hold wildcards (UniFi 400s the whole batch) → `dns-scope=public-only` workaround |
| Site-internal zones | UniFi + `DNSEndpoint`s in `home/dnsrecords/` | e.g. `k8s.killinit.internal → 192.168.169.25` | `killinit.internal`, `robbinsdale.internal`/`.lan`, `stpetersburg.internal` |
| Public | Cloudflare | `externaldns-<domain>.yaml` (CRD source, `dns-target==cloudflare`, `policy: sync`, `txtOwnerId <domain>-${LOCATION}`) + `cloudflare-ddns` per domain | Stays as is |
| GSLB | k8gb CoreDNS, 3 replicas/cluster | k8gb, `cdn.keiretsu.top` NS-delegated | Exposed on the tailnet as `<site>-k8gb-coredns` |
| Pods | Cluster CoreDNS + NodeLocal DNS (`kube-system/cilium-<site>/config/`) | hand-written server blocks | `cdn.keiretsu.top → k8gb VIP`, `keiretsu.top` hosts override (forgejo → private Envoy VIP, DSR hairpin fix), `ts.net → .69.50`, default → 1.1.1.1. Talos `hostDNS` disabled |
| Tailnet | Tailscale split DNS via `tsddns` (`tailscale-system-app/tsddns/config.json`) + `DNSConfig` nameserver at `.69.50` | cronjob pushes split-DNS config | Our zones → all three k8gb CoreDNS services; `*.internal`/`.lan` → the UniFi gateways; `k8s` → `tsdnsproxy` |
| Pi-hole | **Already retired** (`docs/reference/architecture.md`, `tailscale-integration.md`) | — | Only ad blocking we have now is whatever UniFi does natively |

Constraints already on record:

- **ADR 0008** — the internal plane serves a *subset* of public zones, so it
  needs **negative passthrough**: answer the names we own locally and forward
  everything else (NXDOMAIN *and* NODATA) upstream, per name and type. That
  ruled out CoreDNS+etcd. Any replacement has to meet the same bar.
- **UCG load.** Kartik reported UCG disk/CPU pressure tied to unpoller polling
  plus external-dns-unifi doing full `sync` reads/writes of the static-DNS
  table every minute from three sites with debug logging. Moving record
  storage off the gateway removes the external-dns half of that load entirely.

Today that's **five places that hold DNS truth**: UniFi static DNS ×3, cluster
CoreDNS hand edits ×3, k8gb, Tailscale split-DNS JSON, and Cloudflare.

## 2. Options

| | Technitium | Blocky + CoreDNS/k8s_gateway | PowerDNS Auth + Recursor + dnsdist | AdGuard Home | Stay on UniFi |
|---|---|---|---|---|---|
| Authoritative + recursive + blocking in one | **Yes, one binary** | No: Blocky (block/forward) + CoreDNS (auth) | No: three daemons (blocking via RPZ/Lua) | Forward + block; "rewrites" only, not real zones | Forward + static entries; basic blocking |
| ADR 0008 negative passthrough | **Conditional Forwarder zone with local records** — local names answer, others forward; NO DATA app for per-type overrides (must verify NODATA→forward behaviour in a lab before cutover) | k8s_gateway answers only names it has, fallthrough works per name; still CoreDNS-plugin territory | Recursor `forward-zones` + Auth zone doesn't passthrough per name; needs Lua | Rewrites are per-name, rest forwarded — works but no API for external-dns | Works today (that's why it stayed) |
| HA / multi-site | v14 **Clustering** (catalog zones, manage any node, v14.3 syncs secondary + forwarder zones) | Stateless replicas; config via Git | Mature primary/secondary, DB replication | adguardhome-sync (third-party) | One gateway per site, no HA |
| GitOps / declarative | HTTP API + config backup; no native declarative file (records come from external-dns anyway; settings via a small bootstrap job) | **Fully declarative** YAML | Declarative-ish (zone DB/API) | YAML file, rewritten by UI | None (API only) |
| external-dns | **RFC2136 (TSIG)**, incl. into forwarder zones, per-name/type update policy | k8s_gateway reads the cluster directly (no external-dns) | Native `pdns` provider | Community webhook | kashalls webhook (current) |
| DoH / DoT / DoQ | All, server + upstream | Blocky: DoH/DoT upstream + DoH serve | dnsdist: all | All | Limited |
| DHCP | Built in (optional) | No | No (Kea separately) | Built in | Yes (current) |
| Resources | ~150–300 MiB .NET, light CPU | Very light (Go) | Moderate, 3 processes | Light (Go) | On the gateway CPU we're trying to relieve |
| Maturity | Active, single main maintainer, frequent releases; clustering ~1 yr old | Both mature | Most mature, most moving parts | Mature, home-focused | — |
| Things to manage | **1** | 2 + cluster dependency | 3 | 1, but weak authoritative | The status quo |

## 3. Recommendation: Technitium, one cluster across the three sites

**Why:** it's the only option that does authoritative + recursive + blocking +
DoH/DoT in one thing, meets ADR 0008 via conditional-forwarder zones, takes
external-dns over standard RFC2136, and has built-in multi-node clustering.
It collapses UniFi static DNS, Pi-hole (gone) and most cluster CoreDNS hand
edits into one place.

### Where it runs

- **Primary node per site, off-cluster:** a small always-on box per site
  (Pi 5 / mini PC, or a VM on hardware that does not depend on Talos/Ceph).
  LAN DNS must not depend on the cluster being up.
- **Optional second node per site in-cluster** (StatefulSet, LoadBalancer IP
  on the LAN, hostNetwork-free) for capacity and as the RFC2136 target close
  to external-dns. Config in this repo: HelmRelease + SOPS'd admin/TSIG
  secrets + a bootstrap Job that applies settings through the API.
- All nodes in one Technitium **cluster** over the tailnet; zones are members
  of the cluster catalog so every node has every zone.

### How clients reach it

- UniFi DHCP at each site hands out **DNS1 = local Technitium Pi, DNS2 =
  local in-cluster node (or the other site's Pi over site-to-site)**. UniFi
  keeps DHCP; Technitium DHCP is not needed and would be one more thing to
  migrate.
- **Fallback:** the gateway's own resolver stays as a last-resort DNS3 /
  manual revert target for the first month; after that, DNS2 is the other
  site's Technitium node. A cluster outage only takes out the in-cluster
  node; the Pi keeps answering from its replicated copy.
- Tailscale split DNS (`tsddns`) points `*.internal`/`.lan` at the Technitium
  nodes' tailnet IPs instead of the gateways.

### Zones

- `killinit.cc`, `keiretsu.top`, `rajsingh.info`: **Conditional Forwarder
  zones** (forward → 1.1.1.1/9.9.9.9 over DoT) with local records written by
  external-dns. Public answers still come from Cloudflare.
- `cdn.keiretsu.top`: forwarder/stub to the k8gb CoreDNS services (k8gb keeps
  GSLB).
- `killinit.internal`, `robbinsdale.internal`, `stpetersburg.internal`:
  **primary zones**, records from external-dns + DHCP-lease import if wanted.
- Luke's `lukehouge.com`: **unchanged** — keep it on its current path until
  Luke opts in; the new external-dns instance does not include it.
- Blocklists: one shared list set (e.g. Hagezi Pro) applied cluster-wide;
  per-client allowlists where needed.

### external-dns

Replace the `external-dns-unifi` HelmRelease with an `external-dns-technitium`
one: `provider: rfc2136`, TSIG key from SOPS, same sources/label filters,
`txtOwnerId` unchanged per site, `--interval=5m` + `--events` instead of 1m
polling, `logLevel: info`. Wildcards work again, so the `dns-scope=public-only`
workaround can go.

## 4. Migration

1. **Lab** (one Pi, no client traffic): install Technitium, create the forwarder
   zones, point a throwaway external-dns at it with `policy: upsert-only`.
   **Gate:** prove ADR 0008 — a locally-held A name returns the local answer,
   its AAAA forwards (or is handled by the NO DATA app as intended), an unknown
   name forwards, wildcards apply. Write the result into ADR 0008 as a
   follow-up.
2. **Ottawa shadow:** run `external-dns-technitium` alongside
   `external-dns-unifi` (both write; nothing points at Technitium yet). Diff
   answers for every record with a script under `tools/`.
3. **Ottawa cutover:** change UniFi DHCP DNS servers (one setting); keep
   gateway as DNS3. Watch 48h. Rollback = revert the DHCP setting.
4. Robbinsdale, then St. Pete, same steps. Form the cluster.
5. Point `tsddns` `*.internal`/`.lan` entries at Technitium; simplify cluster
   CoreDNS: forward `keiretsu.top`/`killinit.cc`/`rajsingh.info` to the local
   Technitium node instead of hand-written `hosts` blocks (the forgejo
   private-VIP override becomes a normal record).
6. Remove `external-dns-unifi` and clear UniFi static-DNS entries.

## 5. What gets removed

- `external-dns-unifi` ×3 and its UniFi API keys (and the UCG load it causes).
- UniFi static-DNS entries and the `dns-scope=public-only` wildcard workaround.
- Hand-maintained split-horizon `hosts` blocks in cluster CoreDNS (kept:
  `cluster.local`, `ts.net`, `cdn.keiretsu.top`).
- Gateway IPs as resolvers in `tsddns`.

Stays: Cloudflare + its external-dns, cloudflare-ddns, k8gb, Tailscale
DNSConfig/`tsdnsproxy`, UniFi DHCP.

## 6. Open questions for Raj/Kartik

- Hardware per site for the off-cluster node (Pi 5 vs existing always-on box).
- Do we want ad blocking for every LAN client by default, or opt-in per VLAN?
- Luke's domains: leave as-is (default) or ask Luke.
- Is unpoller polling frequency also worth trimming for the UCG load, separately?
