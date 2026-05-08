# tsnet dialer stress tests

Three modes for hammering the tsnet dialer/userspace WireGuard stack. Each
isolates a different layer.

| File | What it tests | Why |
|---|---|---|
| `01-sidecar-socks5.yaml` | Userspace tsnet stack via SOCKS5 in a sidecar | Isolates `tsnet`'s gVisor TCP/IP + userspace WG dialer. Per [tailscale#9707](https://github.com/tailscale/tailscale/issues/9707) this is where throughput drops to ~4Mbps vs ~35Mbps for system tailscaled. |
| `02-proxygroup-ingress.yaml` | The Tailscale operator's tsnet ingress path | What the operator already runs in production. Compare against sidecar mode to see whether the operator adds overhead. |
| `03-custom-xk6-image.yaml` | Custom xk6 build with a `xk6-tsnet` extension calling `tsnet.Server.Dial` directly | Cleanest isolation. Image build is Phase 2 - this file is a placeholder so the structure is in place. |

## Prerequisites

For mode 1, an OAuth-derived auth key with `tag:k8s` must exist in
`k6-operator-system` namespace:

```bash
kubectl create secret generic k6-tsnet-authkey \
  --namespace k6-operator-system \
  --from-literal=TS_AUTHKEY=tskey-auth-XXXX...
```

For mode 2, no extra setup - it uses the existing per-cluster
`${LOCATION}-tailscale-examples-hello-world-service.keiretsu.ts.net` host
managed by the operator's `common-ingress` ProxyGroup.

For mode 3, build the image first (out of scope for v1):

```bash
docker run --rm -it -v "$PWD:/xk6" grafana/xk6 build \
  --with github.com/<owner>/xk6-tsnet
docker tag k6 ghcr.io/<owner>/xk6-tsnet:v0.1.0
docker push ghcr.io/<owner>/xk6-tsnet:v0.1.0
```

## Reading results

Compare these series in Grafana:

```
k6_http_req_duration{transport="tsnet-sidecar"}
k6_http_req_duration{transport="ts-proxygroup-ingress"}
k6_http_req_duration{transport="ts-egress"}    # cross-cluster baseline
```

The dialer-burst test exercises connection establishment specifically. Watch
`k6_http_req_connecting` and `k6_http_req_tls_handshaking`.
