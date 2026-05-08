# k6 TestRun library

Manifests in this tree are **not** auto-applied by Flux. You apply them
manually with `kubectl create -f` (use `create`, not `apply`, so each run gets
a unique name from `generateName`).

## Layout

| Directory | Path being measured | Compare against |
|---|---|---|
| `intra-cluster/` | LAN (Cilium pod-to-pod, same cluster) | baseline |
| `cross-cluster-tailscale/` | Cluster A -> `common-egress` ProxyGroup -> Cluster B | intra-cluster shows TS overhead |
| `cross-cluster-funnel/` | Cluster A pod -> public Internet -> Cluster B Funnel ingress | shows Internet overhead vs TS-overlay |
| `tsnet-stress/` | Three modes that isolate the tsnet userspace stack | each other; see directory README |
| `derp-relay/` | WebSocket sessions through DERP | direct UDP path (when force-DERP'd) |

## Smoke test sequence

After Flux reconciles for the first time, validate end-to-end:

```bash
# 1. operator + ConfigMaps in place
kubectl get pods -n k6-operator-system
kubectl get configmap -n k6-operator-system | grep '^k6-'

# 2. simplest possible run
kubectl create -f intra-cluster/lan-latency.yaml
kubectl get testrun -n k6-operator-system -w

# 3. drill into runner logs
kubectl logs -n k6-operator-system -l app=k6 --tail=200
```

## Tag conventions

Every TestRun should set these env vars on `spec.runner.env`:

- `CLUSTER_SRC`: pulled from the `cluster-settings` ConfigMap (`CLUSTER_NAME` key)
- `CLUSTER_DST`: literal string identifying the destination
- `TRANSPORT`: `lan` | `ts-egress` | `ts-derp` | `ts-proxygroup-ingress` | `tsnet-sidecar` | `tsnet-xk6` | `funnel`
- `PAYLOAD`: `small` | `10mb` | `100mb` | `ws`
- `K6_VERSION`: matches the runner image tag

These flow through to Prometheus as labels, then on to Mimir with
`X-Scope-OrgID: ${CLUSTER_NAME}`. Grafana queries can slice across all
combinations.

## Regression tracking

Pin versions explicitly. `spec.runner.image: grafana/k6:0.55.0` and
`K6_VERSION: 0.55.0`. When you upgrade the Tailscale operator, capture the
old chart version in `TS_OPERATOR_VERSION` for the runs you do before/after.
Mimir retains indefinitely - the dashboards in
`clusters/common/apps/grafana/dashboards/k6/` chart trends over time.

## Phase 2 (not in this iteration)

- Custom xk6-tsnet extension build (`tsnet-stress/03-custom-xk6-image.yaml`
  is a placeholder)
- GitHub Actions workflow for truly-external Funnel testing
- Scheduled / recurring TestRun creation
