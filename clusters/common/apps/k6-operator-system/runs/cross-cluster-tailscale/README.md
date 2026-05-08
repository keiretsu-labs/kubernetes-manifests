# Cross-cluster Tailscale tests

Tests target the existing `hello-world-${TARGET_LOCATION}` ExternalName services
in `tailscale-examples`. These resolve through the `common-egress` ProxyGroup
over the tailnet.

## Quick run

From the source cluster (e.g. Ottawa) hitting Robbinsdale:

```bash
sed 's/TARGET_LOCATION/robbinsdale/g' latency-template.yaml | kubectl create -f -
sed 's/TARGET_LOCATION/robbinsdale/g' bandwidth-template.yaml | kubectl create -f -
```

Valid `TARGET_LOCATION` values:
- `robbinsdale`
- `ottawa`
- `stpetersburg`

## What this measures

Real Tailscale path between clusters. WireGuard will pick direct UDP if both
sides can NAT-traverse, otherwise it falls through to DERP. Look at
`tailscale netcheck` on the egress proxy pods to see which path was used.

## Tagging

Results are tagged `transport=ts-egress`. Compare against `transport=lan`
(intra-cluster) and `transport=funnel` (public Internet) in Grafana to
quantify the overhead.
