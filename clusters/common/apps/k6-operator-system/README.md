# k6-operator-system

Distributed load testing across the three clusters (Robbinsdale, Ottawa, St. Petersburg)
with explicit comparison of LAN / Tailscale-overlay / DERP-relay / public-Funnel paths.

## Layout

```
k6-operator-system/
├── install/         k6-operator HelmRelease (auto-applied by Flux)
├── tests/           k6 JS scripts as ConfigMaps (auto-applied by Flux)
│   ├── lib/         shared modules: tags.js, thresholds.js, helpers.js
│   ├── *.js         per-test scripts
│   └── kustomization.yaml   bundles each script + lib into one ConfigMap per test
└── runs/            TestRun manifests (NOT auto-applied; manual kubectl create)
    ├── intra-cluster/             baseline LAN
    ├── cross-cluster-tailscale/   via common-egress ProxyGroup
    ├── cross-cluster-funnel/      via public Internet
    ├── tsnet-stress/              three modes for dialer isolation
    └── derp-relay/                WebSocket through DERP
```

## How a TestRun finds its script

The k6-operator mounts the script ConfigMap at `/test/`. Each test ConfigMap
in `tests/` bundles its own JS file plus the shared lib files via Kustomize's
`configMapGenerator` with file aliasing:

```yaml
files:
  - latency.js
  - tags.js=lib/tags.js          # alias: stored at lib/tags.js, mounted as tags.js
```

so the test script can `import { commonTags } from './tags.js'` and resolve.

## Running a test

See `runs/README.md` for the full guide. Smoke test:

```bash
kubectl create -f runs/intra-cluster/lan-latency.yaml
kubectl get testrun -n k6-operator-system -w
```

## Where results land

Each runner pod uses `experimental-prometheus-rw` to push to the cluster's
local Prometheus (`kube-prometheus-stack-prometheus.monitoring`) which already
forwards to Mimir with `X-Scope-OrgID: ${CLUSTER_NAME}` (see
`monitoring/app/helmrelease-kube-prometheus-stack.yaml`).

In Grafana, use the Mimir datasource. Dashboard pack lives in
`clusters/common/apps/grafana/dashboards/k6/`.

## Test target reuse

Tests reuse existing `hello-world` infrastructure in `tailscale-examples`:

- `/` for latency tests
- `/10mb` and `/100mb` for bandwidth tests
- LoadBalancer + Ingress (Tailscale) + Funnel Ingress all defined in
  `tailscale-examples/sandbox/hello/service-hello-world.yaml`
- Cross-cluster ExternalName services (`hello-world-${LOCATION}`) in
  `tailscale-examples/sandbox/hello/egress.yaml`

DERP tests target the local `derper` deployment at `derp.${CLUSTER_DOMAIN}`.

## First-run gotcha for cross-cluster TS tests

When a brand-new VIPService is advertised by the common-ingress ProxyGroup,
the common-egress ProxyGroup pods need 30-60 seconds to discover it through
the control plane. Until then, egress logs show:

```
error fetching backend addresses for "X-tailscale-examples-hello-world-service.keiretsu.ts.net":
could not find Tailscale node or service
```

This clears on its own. Confirm the path is ready before running the test:

```bash
kubectl exec -n tailscale common-egress-0 -c tailscale -- \
  tailscale dns query <target>-tailscale-examples-hello-world-service.keiretsu.ts.net
# expect: A record returning a 100.x.y.z VIP
```

Once that resolves, `kubectl create -f runs/cross-cluster-tailscale/...`
will succeed end-to-end.

## Verified end-to-end (sample, from talos-ottawa)

| dst | transport | P95 |
|---|---|---|
| (same cluster) | lan | 0.26 ms |
| robbinsdale | ts-egress | 18.7 ms |
| stpetersburg | ts-egress | 51.6 ms |
| ottawa (Funnel hairpin) | funnel | 63.5 ms |

## Phase 2

- Custom `xk6-tsnet` extension and image build
- GitHub Actions workflow for truly-external runner (in addition to in-cluster
  Funnel testing)
- Scheduled recurring runs (CronJob or k8s schedule)
