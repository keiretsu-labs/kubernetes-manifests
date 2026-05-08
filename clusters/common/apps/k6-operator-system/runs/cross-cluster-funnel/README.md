# Public-Internet (Tailscale Funnel) tests

Tests the public Internet path: pod -> cluster egress NAT -> public Internet ->
Funnel ingress -> hello-world.

## Prerequisites

The Funnel-enabled Ingress needs to be live in the target cluster. It's defined
in `clusters/common/apps/tailscale-examples/sandbox/hello/service-hello-world.yaml`
as `${LOCATION}-tailscale-examples-hello-world-funnel`. Verify the Funnel URL is
reachable from outside before running:

```bash
curl -v https://robbinsdale-tailscale-examples-hello-world-funnel.keiretsu.ts.net
```

## Quick run

```bash
sed -e 's/TARGET_LOCATION/robbinsdale/g' -e 's/TAILNET_DOMAIN/keiretsu.ts.net/g' \
  latency-template.yaml | kubectl create -f -
```

## Caveats

- Hairpin routing: if the cluster's external IP and the Funnel public IP
  happen to share an upstream that NATs locally, the request may not reach
  the real Internet. Verify by checking source IP on the receiving Funnel
  ingress pod logs.
- TLS: Funnel certs are auto-provisioned via Let's Encrypt staging in some
  setups. `--insecure-skip-tls-verify` is set as a safety net; remove it
  if you want strict TLS validation.
- Phase 2 will add a GitHub Actions workflow that runs k6 from a truly
  external runner (Microsoft-hosted) to remove the hairpin question.
