# New-app worked example (copy-paste, then rename)

Concrete skeleton for a raw-manifest app exposed on the tailnet. Copy these
files verbatim, replace `myapp`/image/port, and you have a deployable app.
Reading this once replaces grepping the tree for the pointer shape, the
`substituteFrom` stack, the `CLUSTER_DOMAIN` value, and an HTTPRoute example.

## Domain cheat-sheet (no need to grep `clusters/*/flux/vars`)

| cluster            | `${CLUSTER_DOMAIN}` |
|--------------------|---------------------|
| talos-ottawa       | `killinit.cc`       |
| talos-robbinsdale  | `lukehouge.com`     |
| talos-stpetersburg | `rajsingh.info`     |

`${COMMON_DOMAIN}` = `keiretsu.top` (all clusters). The `ts` gateway (ns
`home`) listens on `*.killinit.cc *.lukehouge.com *.rajsingh.info
*.ts.keiretsu.top`, so `myapp.${CLUSTER_DOMAIN}` always matches — no CNAME
needed. A `${COMMON_DOMAIN}` hostname does NOT auto-resolve: add a CNAME in
`kubernetes/apps/base/k8gb/k8gb-common/config/cnames.yaml` (see AGENTS.md).

## base — `kubernetes/apps/base/<ns>/myapp/`

`kustomization.yaml`
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <ns>
resources:
  - deployment.yaml
  - service.yaml
  - httproute.yaml
```

`deployment.yaml`
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: myapp
    spec:
      containers:
        - name: myapp
          image: <image>:<tag>
          ports:
            - name: http
              containerPort: <port>
```

`service.yaml`
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: myapp
spec:
  selector:
    app.kubernetes.io/name: myapp
  ports:
    - name: http
      port: 80
      targetPort: http
```

`httproute.yaml` (drop this file if the app is not exposed)
```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ts            # 'ts' tailnet-only | 'private' | 'public' — all in ns home
      namespace: home
  hostnames:
    - "myapp.${CLUSTER_DOMAIN}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp
          port: 80
```

## pointer — `kubernetes/apps/<location>/<ns>/myapp.yaml`

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app myapp
  namespace: flux-system
spec:
  targetNamespace: <ns>
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/base/<ns>/myapp
  prune: true
  sourceRef:
    kind: GitRepository
    name: kubernetes-manifests
  interval: 30m
  retryInterval: 1m
  timeout: 5m
  postBuild:
    substituteFrom:
      - { kind: ConfigMap, name: common-settings }
      - { kind: Secret,    name: common-secrets }
      - { kind: ConfigMap, name: cluster-settings, optional: true }
      - { kind: Secret,    name: cluster-secrets,  optional: true }
```

Then add `- ./myapp.yaml` to `kubernetes/apps/<location>/<ns>/kustomization.yaml`
and verify with `tools/check.sh <location>` (e.g. `tools/check.sh talos-ottawa`).

## Helm instead of raw

Swap the three base manifests for a single `helmrelease.yaml` and list it in
`kustomization.yaml`. The pointer, overlay wiring, and verify step are
identical. New chart source? Add a HelmRepository under
`clusters/common/flux/repositories/helm/` first (see AGENTS.md add-app step 1).
