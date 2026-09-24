# An internal DNS overlay needs negative passthrough, which CoreDNS+etcd lacks

Status: recommended decision, 2026-09-24

## Decision

`external-dns-unifi` stays. Do not replace it with an in-cluster authoritative
resolver backed by the CoreDNS `etcd` plugin and the external-dns `coredns`
provider.

The internal DNS planes serve a *subset* of zones that are public and not ours
to own: `killinit.cc`, `lukehouge.com`, `rajsingh.info` and `keiretsu.top` all
have live Cloudflare-hosted records for names no gateway here terminates. An
internal resolver for those zones therefore has to answer two ways — from
cluster state for the names we serve, and from upstream for everything else —
and it has to make that split per *name and type*, not per zone. That is
negative passthrough: forward on NXDOMAIN and on NODATA.

Stock CoreDNS cannot do it. The `etcd` plugin's `fallthrough` fires only on
`errKeyNotFound`, so a name that exists in etcd is terminal for every query
type, and a name with descendants answers for its descendants. Both cases
return a wrong answer rather than falling through.

This is a posture, not a code change. `external-dns-unifi` and the #3189
tailnet leg keep working exactly as they do today.

## Facts at decision time

Live DNS observed 2026-09-24 against `1.1.1.1`; source facts read from
CoreDNS `v1.14.7` and external-dns `master`.

| Fact | Observed |
| --- | --- |
| Apex records we do not own | `killinit.cc`, `lukehouge.com` and `rajsingh.info` each publish an apex `MX` set plus an SPF `TXT`. Mail is Cloudflare Email Routing on two and privateemail.com on the third. Only `keiretsu.top` has neither. |
| `etcd` plugin apex behaviour | An address query at a zone apex resolves to the key prefix `/skydns/<reversed zone>/` and is fetched with `WithPrefix()`. With no wildcard in the question the per-key filter in `loopNodes` is skipped entirely, so every record in the zone is unmarshalled and returned — as answers for the queried name. |
| …and it is not only the apex | The same prefix fetch applies to any name with descendants. With `oci.cdn.keiretsu.top` in the overlay, a query for `cdn.keiretsu.top` answers with `oci`'s address. |
| `fallthrough` scope | `Etcd.IsNameError` matches `errKeyNotFound` alone. A key that exists but carries no record of the queried type is NODATA, and NODATA does not fall through. Apex `MX` and apex `TXT` would stop resolving on the LAN and on the tailnet. |
| `no_apex_fallback` | Documented on CoreDNS `master`; absent from the `plugin/etcd` README in `v1.14.7`, `v1.14.0` and `v1.13.1`. Not available to pin. |
| Wildcard support | Query-side only. `msg.PathWithWildcard` expands `*` or `any` found in the *question*; a stored `*.keiretsu.top` key is never matched by a concrete name. The overlay would not have gained the wildcards UniFi's static-DNS API rejects. |
| Can the apex be routed past the plugin | No. CoreDNS server blocks match by longest zone suffix and have no exact-name form, so a block cannot cover a zone while excluding its apex. `template` matches exactly and runs earlier in the chain, but it synthesises answers and cannot proxy. |
| The plugin's own scope statement | `plugin/etcd/README.md`: "not suitable as a generic DNS zone data plugin". |
| external-dns key layout | `--coredns-prefix` defaults to `/skydns/`; `etcdKeyFor` reverses the labels and appends a random 8-hex child, which is what makes the per-name prefix fetch work for leaf names. |

The resolver side was never confirmed either. UniFi OS gateways expose static
DNS records and a global upstream list; per-zone conditional forwarding is not
a Network-application feature, and `config.gateway.json` — the documented way
to inject `server=/zone/ip` — applies to the USG and not to the UCG and UDM
gateways in service here. Both remaining options are worse than what we have:
hand-edited dnsmasq dropins do not survive a provision, and swapping the
global upstream to an in-cluster address makes every name at the site depend
on the cluster, with a second upstream that would answer internal names from
public DNS whenever it won the race.

`external-dns-unifi`'s real cost is narrower than it looked: a UniFi API key,
and no wildcard records. The second is not a regression the overlay would have
fixed, and no internal record needs a wildcard — listener hostnames are
wildcards, route hostnames are concrete, and the one wildcard table we have
(`keiretsu-top-cnames`) is public-edge targets that belong only in Cloudflare.

## If this is revisited

Three paths, in preference order. All three need the resolver question settled
first, because none of them is reachable without a supported per-site change.

1. **A CoreDNS build carrying `alternate`.** That plugin forwards on chosen
   rcodes, which is exactly the negative passthrough the design needs: apex
   `MX`, apex `TXT` and every overlay miss pass upstream, and the etcd data
   answers only what it holds. It is out-of-tree, so it costs a custom image
   and a pipeline to build and push it — the same shape as any other
   plugin-carrying CoreDNS. This is the only variant that is actually correct.
2. **Overlay only zones with no public counterpart.** `killinit.internal`,
   `robbinsdale.internal` and `stpetersburg.internal` have no apex we do not
   own and no upstream to fall through to, so a fully authoritative answer is
   right for them. They are also entirely static today
   (`base/home/home/dnsrecords/`), so this buys nothing but consistency.
3. **`k8s_gateway` instead of etcd.** Reads routes directly, so no etcd and no
   external-dns. Rejected: it has no gateway-class or label filter, so it
   answers with every address in `gateway.status.addresses` across all of a
   route's `parentRefs` — mixing the private LB, the public LB and the
   Tailscale address into one A set. It is also A-only. `external-dns`'s
   `--gateway-label-filter=gateway==private` is the thing that makes the
   internal answer correct, and `k8s_gateway` has no equivalent.

A `Gslb` per app was the original suggestion and is not on this list: k8gb
resolves a GSLB name to the participating clusters' external addresses, which
is the public path, and it would need one CR per exposed route.
