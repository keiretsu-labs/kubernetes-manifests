#!/usr/bin/env bash
# tools/check-domain-dns.sh — assert that every domain a gateway serves can
# actually be resolved, from every vantage point that is supposed to reach it.
#
# A hostname only works when two independent things agree: a Gateway listener
# terminates it, and some DNS plane publishes a record for it. Those live in
# different apps, so they drift silently — the route reports Accepted=True and
# the name resolves somewhere else entirely. That is not a visible failure; it
# is a 404 from one network and a success from another.
#
# The three planes and who feeds them:
#
#   LAN      external-dns-unifi        gateway==private routes  -> private LB
#   tailnet  k8gb CoreDNS split DNS    per-zone Corefile answer
#   internet external-dns-cloudflare   gateway==public routes   -> WAN edge
#
# Invariants, stated as rules rather than as the current values:
#
# 1. private and ts terminate the same HTTPS hostnames. They are the two
#    internal edges; anything reachable from the LAN should be reachable from
#    the tailnet, and a listener present on one but not the other is how that
#    stops being true.
#
# 2. Every registrable domain in any listener hostname appears in at least one
#    external-dns domainFilter. A zone no instance watches gets no records at
#    all, which is how *.keiretsu.top sat attached-and-Programmed on private in
#    all three clusters while every one of its names resolved to the WAN.
#
# 3. Every registrable domain served by private or ts has an explicit answer in
#    the k8gb Corefile — a tailnet-regional template or its own <zone>:5353
#    block. Reaching the bare `forward . 1.1.1.1` catch-all means tailnet
#    clients get the public answer for a service sitting one hop away.
#
# 4. Any DNSEndpoint pointing a zone at the public edge must be labelled
#    dns-scope=public-only once external-dns-unifi watches that zone, or those
#    CNAMEs land in LAN DNS and shadow the private-LB records derived from the
#    gateway's own routes.
#
# 5. Nobody addresses an Envoy Gateway data plane by its generated name.
#
# 6. Where an internal zone's tailnet answer forwards to the site resolver with
#    a public resolver behind it, the public one stays strictly last. forward
#    defaults to policy random, which would race them and answer a share of
#    every internal lookup from public DNS.
#
# 7. No DNSEndpoint asserts cloudflare-proxied: "false". That is already the
#    provider default, and asserting it is the one structural difference
#    between the CRD-sourced endpoints -- every record of which external-dns
#    rewrote on every reconcile -- and the gateway-sourced ones, which
#    converge.
#
# Offline: reads tracked YAML only, no cluster calls. Exit 1 on any violation.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

import yaml

root = pathlib.Path(sys.argv[1])
problems = []

GATEWAYS = {
    "private": "kubernetes/apps/base/home/home/local-gateway/gateway-private.yaml",
    "public": "kubernetes/apps/base/home/home/local-gateway/gateway-public.yaml",
    "ts": "kubernetes/apps/base/home/home/tailscale-gateway/gateway.yaml",
}
UNIFI = "kubernetes/apps/base/home/home/local-gateway/external-dns-unifi.yaml"
CLOUDFLARE_DIR = "kubernetes/apps/base/cloudflare/cloudflare"
K8GB = "kubernetes/apps/base/k8gb/k8gb-common/app/helmrelease.yaml"
CNAMES = "kubernetes/apps/base/k8gb/k8gb-common/config/cnames.yaml"


def load_all(rel):
    path = root / rel
    if not path.is_file():
        problems.append(f"missing file: {rel}")
        return []
    return [d for d in yaml.safe_load_all(path.read_text()) if d]


def flux_vars():
    """${VAR} -> every value it can take across the fleet.

    Hostnames in these files are written pre-substitution, and the var is not
    always a leading label: cnames.yaml says "${COMMON_DOMAIN}" for the apex,
    which has no literal tail to fall back on. Resolve before splitting.
    """
    values = {}
    common = root / "clusters/common/flux/vars/common-settings.yaml"
    for doc in load_all(common.relative_to(root)):
        for k, v in (doc.get("data") or {}).items():
            values.setdefault(k, set()).add(str(v))
    for path in sorted(root.glob("clusters/talos-*/flux/vars/cluster-settings.yaml")):
        for doc in load_all(path.relative_to(root)):
            for k, v in (doc.get("data") or {}).items():
                values.setdefault(k, set()).add(str(v))
    return values


VARS = flux_vars()


def expand(hostname):
    """All concrete hostnames a templated hostname can render to."""
    out = {hostname}
    for _ in range(4):  # vars never nest more than a level or two here
        grown = set()
        for h in out:
            m = re.search(r"\$\{(\w+)[^}]*\}", h)
            if not m:
                grown.add(h)
                continue
            for v in VARS.get(m.group(1), {"__unresolved__"}):
                grown.add(h[: m.start()] + v + h[m.end() :])
        if grown == out:
            break
        out = grown
    return out


def registrable(hostname):
    """Zone a record would be written into: the last two labels."""
    return ".".join(hostname.strip("*.").split(".")[-2:])


def zones_of(hostname):
    return {
        registrable(h) for h in expand(hostname) if "__unresolved__" not in h
    }


# ---------------------------------------------------------------- listeners
listeners = {}
for name, rel in GATEWAYS.items():
    for doc in load_all(rel):
        if doc.get("kind") == "Gateway" and doc["metadata"]["name"] == name:
            listeners[name] = [
                l for l in doc["spec"]["listeners"] if l.get("protocol") == "HTTPS"
            ]
            break
    else:
        problems.append(f"no Gateway/{name} in {rel}")

served = {n: {l["hostname"] for l in ls} for n, ls in listeners.items()}
zones = sorted({z for hs in served.values() for h in hs for z in zones_of(h)})
internal_zones = sorted(
    {z for n in ("private", "ts") for h in served.get(n, ()) for z in zones_of(h)}
)

# 1. private and ts must terminate the same HTTPS hostnames.
if "private" in served and "ts" in served:
    only_private = sorted(served["private"] - served["ts"])
    only_ts = sorted(served["ts"] - served["private"])
    for h in only_private:
        problems.append(
            f"listener {h!r} is on private but not ts — reachable from the LAN, "
            f"404 from the tailnet"
        )
    for h in only_ts:
        problems.append(
            f"listener {h!r} is on ts but not private — reachable from the "
            f"tailnet, 404 from the LAN"
        )

# 2. Every served zone is watched by the external-dns instance that feeds the
#    plane serving it. Per-plane, not "somebody watches it": keiretsu.top has
#    been in the Cloudflare instance's domainFilters all along, which is what
#    made the missing LAN coverage invisible.
unifi_zones = set()
for doc in load_all(UNIFI):
    unifi_zones.update(
        (doc.get("spec", {}).get("values", {}) or {}).get("domainFilters", [])
    )
cloudflare_zones = set()
cloudflare_values = []
for path in sorted((root / CLOUDFLARE_DIR).glob("externaldns-*.yaml")):
    for doc in load_all(path.relative_to(root)):
        vals = doc.get("spec", {}).get("values", {}) or {}
        cloudflare_values.append(vals)
        cloudflare_zones.update(vals.get("domainFilters", []))

for gw, feeder, have in (
    ("private", "external-dns-unifi", unifi_zones),
    ("ts", "external-dns-unifi", unifi_zones),
    ("public", "external-dns-cloudflare-*", cloudflare_zones),
):
    for z in sorted({z for h in served.get(gw, ()) for z in zones_of(h)}):
        if z not in have:
            problems.append(
                f"zone {z} is terminated by the {gw} gateway but {feeder} does "
                f"not have it in domainFilters — that plane will never publish "
                f"a record, so the name resolves wherever the others point it"
            )

# 3. Every internal zone has an explicit tailnet answer in the k8gb Corefile.
corefile = (root / K8GB).read_text() if (root / K8GB).is_file() else ""
for z in internal_zones:
    pinned = re.search(rf"template IN ANY {re.escape(z)}\b", corefile)
    zoned = re.search(rf"^\s*{re.escape(z)}:5353\s*\{{", corefile, re.M)
    if not (pinned or zoned):
        problems.append(
            f"zone {z} is served by an internal gateway but the k8gb Corefile "
            f"has neither a tailnet-regional template nor a {z}:5353 block — "
            f"tailnet clients fall through to the public resolver"
        )

# 4. Public-edge CNAME tables stay out of any zone UniFi now watches.
for doc in load_all(CNAMES):
    if doc.get("kind") != "DNSEndpoint":
        continue
    labels = doc["metadata"].get("labels", {}) or {}
    name = doc["metadata"]["name"]
    if labels.get("dns-scope") == "public-only":
        continue
    for ep in doc.get("spec", {}).get("endpoints", []):
        overlap = zones_of(ep.get("dnsName", "")) & unifi_zones
        if not overlap:
            continue
        problems.append(
            f"DNSEndpoint {name} publishes {ep['dnsName']} in "
            f"{sorted(overlap)[0]}, which external-dns-unifi watches, but is "
            f"not labelled dns-scope=public-only — these public-edge targets "
            f"would be copied into LAN DNS and shadow the private-LB records "
            f"derived from the private gateway's own routes"
        )
        break

# 5. Nobody addresses an Envoy Gateway data plane by its generated name.
#    EG derives envoy-<gateway-ns>-<gateway-name>-<hash> for the data-plane
#    Service. It is stable, but it is the controller's internal naming, not an
#    API, and a hash nobody can derive by reading the manifests. EnvoyProxy's
#    provider.kubernetes.envoyService.name pins a name we own instead.
generated = re.compile(r"\benvoy(?:-[a-z0-9]+)+-[0-9a-f]{8}\b")
for path in sorted((root / "kubernetes").rglob("*.yaml")):
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = generated.search(line)
        if m:
            problems.append(
                f"{path.relative_to(root)}:{n} hardcodes {m.group(0)!r}, an "
                f"Envoy Gateway generated data-plane Service name — pin one "
                f"with EnvoyProxy provider.kubernetes.envoyService.name and "
                f"reference that instead"
            )

# 6. An internal zone's tailnet forward is ordered, not raced.
#    #3189 answers keiretsu.top on the tailnet by forwarding to the site's own
#    resolver with a public resolver behind it as the unreachable-UniFi
#    fallback. forward's default policy is random, so without an explicit
#    sequential policy CoreDNS would spread internal lookups across both and
#    answer a share of them with the WAN edge -- a 404 for every route
#    attached only to private, intermittently. Asserted as the ordering rule,
#    not as the current pair of addresses.
PUBLIC_RESOLVERS = {
    "1.1.1.1",
    "1.0.0.1",
    "8.8.8.8",
    "8.8.4.4",
    "9.9.9.9",
    "149.112.112.112",
}


def corefile_block(text, header):
    """The body of a `header { ... }` stanza, or None. Brace-counted so a
    nested forward/template block does not truncate it."""
    m = re.search(rf"^\s*{re.escape(header)}\s*\{{", text, re.M)
    if not m:
        return None
    depth = 0
    for i in range(m.end() - 1, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[m.end() : i]
    return None


for z in internal_zones:
    block = corefile_block(corefile, f"{z}:5353")
    if block is None:
        continue  # check 3 owns a missing block
    fwd = re.search(r"^\s*forward\s+\.\s+(.+)$", block, re.M)
    if not fwd:
        continue
    # Strip the optional trailing `{` that opens the forward body. Cannot
    # simply stop the capture at `{` — ${LAN_GATEWAY_IP} contains one.
    upstreams = re.sub(r"\{\s*$", "", fwd.group(1)).split()
    public = [u for u in upstreams if u in PUBLIC_RESOLVERS]
    if len(upstreams) < 2 or not public:
        continue
    if upstreams[0] in PUBLIC_RESOLVERS:
        problems.append(
            f"k8gb Corefile {z}:5353 forwards to {upstreams[0]} before "
            f"{upstreams[1]} — the public resolver has to be the fallback, "
            f"not the primary, or internal names resolve to the WAN edge"
        )
    elif not re.search(r"policy\s+sequential", block):
        problems.append(
            f"k8gb Corefile {z}:5353 forwards to {' '.join(upstreams)} "
            f"without policy sequential — forward defaults to random, so "
            f"{public[0]} would answer a share of every internal lookup with "
            f"the public record and 404 any route attached only to private"
        )

# 7. Nobody asserts the Cloudflare proxied default.
#    --cloudflare-proxied is unset on every instance, so shouldBeProxied()
#    already returns false; a providerSpecific saying so changes nothing about
#    the record. It is not free, though: CRD-sourced endpoints carrying it were
#    rewritten on every reconcile -- roughly 2,280 Cloudflare writes an hour
#    across the fleet -- while the gateway-sourced instances, which set no
#    provider-specific properties, reported "All records are already up to
#    date" every cycle. Keep the property for records that must be proxied.
proxied_default_on = any(
    "--cloudflare-proxied" in str(vals.get("extraArgs", []))
    for vals in cloudflare_values
)
if not proxied_default_on:
    for path in sorted((root / "kubernetes").rglob("*.yaml")):
        try:
            docs = list(yaml.safe_load_all(path.read_text()))
        except yaml.YAMLError:
            continue
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "DNSEndpoint":
                continue
            for ep in doc.get("spec", {}).get("endpoints", []) or []:
                for prop in ep.get("providerSpecific", []) or []:
                    if prop.get("name", "").endswith("cloudflare-proxied") and str(
                        prop.get("value")
                    ).lower() == "false":
                        problems.append(
                            f"{path.relative_to(root)} DNSEndpoint "
                            f"{doc['metadata']['name']} declares "
                            f"cloudflare-proxied: \"false\" on "
                            f"{ep.get('dnsName')} — that is the provider "
                            f"default, so it asserts nothing, and CRD "
                            f"endpoints carrying it were rewritten on every "
                            f"reconcile; drop the property"
                        )

# ---------------------------------------------------------------- report
if problems:
    print("domain/DNS coverage check FAILED:\n", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)

print(
    f"✓ domain DNS OK: {len(zones)} zone(s) served "
    f"({', '.join(zones)}); private/ts listener sets match; "
    f"every internal zone has a tailnet answer"
)
PY
