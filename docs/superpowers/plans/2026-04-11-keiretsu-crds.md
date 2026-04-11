# Keiretsu CRD System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a composable set of KRO ResourceGroupDefinitions that abstract cross-cluster networking, storage/backup, routing, and GSLB into reusable Keiretsu CRDs — then wire them into ArgoCD for multi-cluster placement.

**Architecture:** 6 KRO RGDs (ServiceIngress, ServiceEgress, StorageStack, AppRoute, GSLBEndpoint, KeiretsuApp) + 1 Platform ConfigMap. RGDs live in `clusters/common/apps/kro/rgd/` managed by Flux. CRD instances live in `clusters/apps/` managed by ArgoCD ApplicationSets. StorageStack includes a probe Job for auto-detecting whether backup history exists, eliminating the manual freshInstall toggle.

**Tech Stack:** KRO v0.9.1, Tailscale Operator, Volsync, Garage Operator, k8gb, Gateway API, ArgoCD ApplicationSets, Flux CD

**Spec:** `docs/superpowers/specs/2026-04-11-keiretsu-crds-design.md`

**kubectl contexts:**
- Ottawa: `ottawa-k8s-operator.keiretsu.ts.net`
- Robbinsdale: `robbinsdale-k8s-operator.keiretsu.ts.net`
- St. Petersburg: `stpetersburg-k8s-operator.keiretsu.ts.net`

---

## Phase 1: Foundation — Platform ConfigMap + ServiceIngress + ServiceEgress

### Task 1: Platform ConfigMap

**Files:**
- Create: `clusters/common/apps/kro/config/keiretsu-platform-config.yaml`
- Create: `clusters/common/apps/kro/config/kustomization.yaml`
- Modify: `clusters/common/apps/kro/kustomization.yaml`
- Modify: `clusters/common/apps/kro/ks.yaml` (add new Flux Kustomization for config)

- [ ] **Step 1: Create the ConfigMap**

```yaml
# clusters/common/apps/kro/config/keiretsu-platform-config.yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: keiretsu-platform-config
  namespace: kro-system
data:
  # Gateway references (used by AppRoute)
  gateway.ts.name: "ts"
  gateway.ts.namespace: "home"
  gateway.private.name: "private"
  gateway.private.namespace: "home"
  gateway.public.name: "public"
  gateway.public.namespace: "home"

  # Storage defaults (used by StorageStack)
  storage.defaultStorageClass: "ceph-block-replicated-nvme"
  storage.defaultSnapshotClass: "csi-rbdplugin-snapclass"
  storage.defaultBucket: "keiretsu"
  storage.s3Endpoint: "${COMMON_S3_ENDPOINT}"
  storage.resticPassword: "${COMMON_RESTIC_SECRET}"

  # Networking defaults (used by ServiceIngress/Egress)
  network.defaultIngressProxyGroup: "common-ingress"
  network.defaultEgressProxyGroup: "common-egress"
  network.defaultLocalTags: "tag:k8s,tag:${LOCATION}"
  network.defaultGlobalTags: "tag:k8s"
  network.location: "${LOCATION}"

  # Cluster topology (used by ServiceEgress)
  clusters: "ottawa,robbinsdale,stpetersburg"
```

- [ ] **Step 2: Create kustomization for config dir**

```yaml
# clusters/common/apps/kro/config/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - keiretsu-platform-config.yaml
```

- [ ] **Step 3: Add Flux Kustomization for config**

Add to `clusters/common/apps/kro/ks.yaml` — a new Kustomization that deploys the ConfigMap with Flux variable substitution enabled (unlike the RGDs which have substitution disabled):

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kro-platform-config
  namespace: flux-system
spec:
  targetNamespace: kro-system
  path: ./clusters/common/apps/kro/config
  prune: true
  sourceRef:
    kind: GitRepository
    name: kubernetes-manifests
  dependsOn:
    - name: kro
  interval: 30m
  retryInterval: 1m
  timeout: 5m
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: common-settings
      - kind: Secret
        name: common-secrets
      - kind: ConfigMap
        name: cluster-settings
        optional: true
      - kind: Secret
        name: cluster-secrets
        optional: true
```

- [ ] **Step 4: Update root kustomization**

Add `config` to `clusters/common/apps/kro/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - ks.yaml
  - ks-rgd.yaml
```

Note: `ks.yaml` already exists — just append the new Kustomization to it. The root kustomization references `ks.yaml` which contains all Flux Kustomizations.

- [ ] **Step 5: Verify on Ottawa**

Wait for Flux to reconcile, then:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get configmap keiretsu-platform-config -n kro-system -o yaml
```

Expected: ConfigMap exists with `${LOCATION}` resolved to `ottawa`, `${COMMON_S3_ENDPOINT}` resolved to the actual endpoint.

- [ ] **Step 6: Commit**

```bash
git add clusters/common/apps/kro/config/ clusters/common/apps/kro/ks.yaml
git commit -m "feat(kro): add keiretsu-platform-config ConfigMap with cluster defaults"
```

---

### Task 2: ServiceIngress RGD

**Files:**
- Create: `clusters/common/apps/kro/rgd/service-ingress.yaml`
- Modify: `clusters/common/apps/kro/rgd/kustomization.yaml`

- [ ] **Step 1: Create the RGD**

```yaml
# clusters/common/apps/kro/rgd/service-ingress.yaml
---
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: serviceingress
  annotations:
    kro.run/allow-breaking-changes: "true"
spec:
  schema:
    group: network.keiretsu.ts.net
    apiVersion: v1alpha1
    kind: ServiceIngress
    scope: Namespaced
    spec:
      # Pod selector
      selector: "object"
      # Ports to expose
      ports:
        type: "[]Port"
        items:
          name: "string | required=true"
          port: "integer | required=true"
          protocol: "string | default=TCP"

      # Per-node VIP (always created)
      hostname: "string | required=true"
      tags: "string | default=tag:k8s"
      proxyGroup: "string | default=common-ingress"
      publishNotReadyAddresses: "boolean | default=false"

      # Global VIP (optional)
      global:
        enabled: "boolean | default=false"
        hostname: "string"
        tags: "string | default=tag:k8s"
        ports:
          type: "[]integer"
        proxyGroup: "string | default=common-ingress"

    status:
      fqdn: ${schema.spec.hostname + ".keiretsu.ts.net"}
      globalFQDN: ${schema.spec.global.enabled ? schema.spec.global.hostname + ".keiretsu.ts.net" : ""}
      tailscaleIP: ${perNodeService.status.?loadBalancer.?ingress[0].?ip.orValue("")}
      ready: ${perNodeService.status.?loadBalancer.?ingress.size() > 0}

  resources:
  # Per-node VIP LoadBalancer
  - id: perNodeService
    template:
      apiVersion: v1
      kind: Service
      metadata:
        name: ${schema.metadata.name + "-ts"}
        annotations:
          tailscale.com/hostname: ${schema.spec.hostname}
          tailscale.com/tags: ${schema.spec.tags}
          tailscale.com/proxy-group: ${schema.spec.proxyGroup}
      spec:
        publishNotReadyAddresses: ${schema.spec.publishNotReadyAddresses}
        selector: ${schema.spec.selector}
        type: LoadBalancer
        loadBalancerClass: tailscale
        ports: ${schema.spec.ports}

  # Global VIP LoadBalancer (optional)
  - id: globalService
    includeWhen:
    - ${schema.spec.global.enabled}
    template:
      apiVersion: v1
      kind: Service
      metadata:
        name: ${schema.metadata.name + "-global-ts"}
        annotations:
          tailscale.com/hostname: ${schema.spec.global.hostname}
          tailscale.com/tags: ${schema.spec.global.tags}
          tailscale.com/proxy-group: ${schema.spec.global.proxyGroup}
      spec:
        publishNotReadyAddresses: ${schema.spec.publishNotReadyAddresses}
        selector: ${schema.spec.selector}
        type: LoadBalancer
        loadBalancerClass: tailscale
        ports: ${schema.spec.global.ports}
```

- [ ] **Step 2: Add to rgd kustomization**

Add `- ./service-ingress.yaml` to `clusters/common/apps/kro/rgd/kustomization.yaml`.

- [ ] **Step 3: Verify CRD registers**

Wait for Flux to reconcile the RGD, then check:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get crd serviceingresses.network.keiretsu.ts.net
```

Expected: CRD exists and is established.

- [ ] **Step 4: Test with a dry-run instance**

Create a test ServiceIngress instance (don't commit — just `kubectl apply` to verify):

```bash
cat <<'EOF' | kubectl --context ottawa-k8s-operator.keiretsu.ts.net apply -f -
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: ServiceIngress
metadata:
  name: test-ingress
  namespace: default
spec:
  selector:
    app: nginx
  ports:
    - name: http
      port: 80
  hostname: test-ingress
  tags: "tag:k8s,tag:ottawa"
  proxyGroup: common-ingress
  global:
    enabled: false
EOF
```

Verify KRO creates the LoadBalancer Service:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get svc test-ingress-ts -n default
```

Expected: LoadBalancer Service exists with `loadBalancerClass: tailscale`.

- [ ] **Step 5: Clean up test**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net delete serviceingress test-ingress -n default
```

- [ ] **Step 6: Commit**

```bash
git add clusters/common/apps/kro/rgd/service-ingress.yaml clusters/common/apps/kro/rgd/kustomization.yaml
git commit -m "feat(kro): add ServiceIngress RGD for Tailscale per-node and global VIPs"
```

---

### Task 3: ServiceEgress RGD

**Files:**
- Create: `clusters/common/apps/kro/rgd/service-egress.yaml`
- Modify: `clusters/common/apps/kro/rgd/kustomization.yaml`

- [ ] **Step 1: Create the RGD**

```yaml
# clusters/common/apps/kro/rgd/service-egress.yaml
---
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: serviceegress
  annotations:
    kro.run/allow-breaking-changes: "true"
spec:
  schema:
    group: network.keiretsu.ts.net
    apiVersion: v1alpha1
    kind: ServiceEgress
    scope: Namespaced
    spec:
      # Per-cluster endpoints
      endpoints:
        type: "[]Endpoint"
        items:
          name: "string | required=true"
          fqdn: "string | required=true"
          ports:
            type: "[]Port"
            items:
              name: "string | required=true"
              port: "integer | required=true"
              protocol: "string | default=TCP"

      # Global endpoint (optional)
      global:
        enabled: "boolean | default=false"
        name: "string"
        fqdn: "string"
        ports:
          type: "[]Port"
          items:
            name: "string | required=true"
            port: "integer | required=true"
            protocol: "string | default=TCP"

      # Proxy routing
      proxyGroup: "string | default=common-egress"

    status:
      ready: "true"

  resources:
  # Per-cluster ExternalName services (forEach over endpoints)
  - id: egressServices
    forEach:
    - ep: ${schema.spec.endpoints}
    template:
      apiVersion: v1
      kind: Service
      metadata:
        name: ${ep.name}
        annotations:
          tailscale.com/tailnet-fqdn: ${ep.fqdn}
          tailscale.com/proxy-group: ${schema.spec.proxyGroup}
      spec:
        externalName: placeholder
        type: ExternalName
        ports: ${ep.ports}

  # Global ExternalName service (optional)
  - id: globalEgressService
    includeWhen:
    - ${schema.spec.global.enabled}
    template:
      apiVersion: v1
      kind: Service
      metadata:
        name: ${schema.spec.global.name}
        annotations:
          tailscale.com/tailnet-fqdn: ${schema.spec.global.fqdn}
          tailscale.com/proxy-group: ${schema.spec.proxyGroup}
      spec:
        externalName: placeholder
        type: ExternalName
        ports: ${schema.spec.global.ports}
```

- [ ] **Step 2: Add to rgd kustomization**

Add `- ./service-egress.yaml` to `clusters/common/apps/kro/rgd/kustomization.yaml`.

- [ ] **Step 3: Verify CRD registers**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get crd serviceegresses.network.keiretsu.ts.net
```

- [ ] **Step 4: Test with a dry-run instance**

```bash
cat <<'EOF' | kubectl --context ottawa-k8s-operator.keiretsu.ts.net apply -f -
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: ServiceEgress
metadata:
  name: test-egress
  namespace: default
spec:
  endpoints:
    - name: ottawa-test
      fqdn: ottawa-test.keiretsu.ts.net
      ports:
        - name: http
          port: 80
    - name: robbinsdale-test
      fqdn: robbinsdale-test.keiretsu.ts.net
      ports:
        - name: http
          port: 80
  global:
    enabled: true
    name: test-global
    fqdn: test.keiretsu.ts.net
    ports:
      - name: http
        port: 80
  proxyGroup: common-egress
EOF
```

Verify 3 ExternalName services created:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get svc -n default ottawa-test robbinsdale-test test-global
```

Expected: 3 ExternalName services with correct `tailscale.com/tailnet-fqdn` annotations.

- [ ] **Step 5: Clean up test**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net delete serviceegress test-egress -n default
```

- [ ] **Step 6: Commit**

```bash
git add clusters/common/apps/kro/rgd/service-egress.yaml clusters/common/apps/kro/rgd/kustomization.yaml
git commit -m "feat(kro): add ServiceEgress RGD for cross-cluster ExternalName services"
```

---

## Phase 2: Routing — AppRoute + GSLBEndpoint

### Task 4: AppRoute RGD

**Files:**
- Create: `clusters/common/apps/kro/rgd/app-route.yaml`
- Modify: `clusters/common/apps/kro/rgd/kustomization.yaml`

- [ ] **Step 1: Create the RGD**

```yaml
# clusters/common/apps/kro/rgd/app-route.yaml
---
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: approute
  annotations:
    kro.run/allow-breaking-changes: "true"
spec:
  schema:
    group: network.keiretsu.ts.net
    apiVersion: v1alpha1
    kind: AppRoute
    scope: Namespaced
    spec:
      # Route type
      kind: "string | default=HTTPRoute"

      # Target service
      backendRef:
        name: "string | required=true"
        port: "integer | required=true"

      # Gateway binding (short names)
      parentGateways:
        type: "[]string"

      # Hostnames (HTTPRoute/TLSRoute/GRPCRoute)
      hostnames:
        type: "[]string"

      # Path rules (HTTPRoute only)
      pathPrefix: "string | default=/"

      # Homer integration (optional)
      homerName: "string"
      homerSubtitle: "string"
      homerLogo: "string"
      homerKeywords: "string"
      homerService: "string"
      homerServiceIcon: "string"

    status:
      ready: ${httproute.metadata.name != ""}

  resources:
  # HTTPRoute
  - id: httproute
    includeWhen:
    - ${schema.spec.kind == "HTTPRoute"}
    template:
      apiVersion: gateway.networking.k8s.io/v1
      kind: HTTPRoute
      metadata:
        name: ${schema.metadata.name}
        annotations:
          item.homer.rajsingh.info/name: ${schema.spec.homerName}
          item.homer.rajsingh.info/subtitle: ${schema.spec.homerSubtitle}
          item.homer.rajsingh.info/logo: ${schema.spec.homerLogo}
          item.homer.rajsingh.info/keywords: ${schema.spec.homerKeywords}
          service.homer.rajsingh.info/name: ${schema.spec.homerService}
          service.homer.rajsingh.info/icon: ${schema.spec.homerServiceIcon}
      spec:
        parentRefs: ${schema.spec.parentGateways.map(gw, {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw, "namespace": "home"})}
        hostnames: ${schema.spec.hostnames}
        rules:
        - backendRefs:
          - group: ""
            kind: Service
            name: ${schema.spec.backendRef.name}
            port: ${schema.spec.backendRef.port}
            weight: 1
          matches:
          - path:
              type: PathPrefix
              value: ${schema.spec.pathPrefix}

  # TCPRoute
  - id: tcproute
    includeWhen:
    - ${schema.spec.kind == "TCPRoute"}
    template:
      apiVersion: gateway.networking.k8s.io/v1alpha2
      kind: TCPRoute
      metadata:
        name: ${schema.metadata.name}
      spec:
        parentRefs: ${schema.spec.parentGateways.map(gw, {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw, "namespace": "home"})}
        rules:
        - backendRefs:
          - group: ""
            kind: Service
            name: ${schema.spec.backendRef.name}
            port: ${schema.spec.backendRef.port}

  # UDPRoute
  - id: udproute
    includeWhen:
    - ${schema.spec.kind == "UDPRoute"}
    template:
      apiVersion: gateway.networking.k8s.io/v1alpha2
      kind: UDPRoute
      metadata:
        name: ${schema.metadata.name}
      spec:
        parentRefs: ${schema.spec.parentGateways.map(gw, {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw, "namespace": "home"})}
        rules:
        - backendRefs:
          - group: ""
            kind: Service
            name: ${schema.spec.backendRef.name}
            port: ${schema.spec.backendRef.port}

  # TLSRoute
  - id: tlsroute
    includeWhen:
    - ${schema.spec.kind == "TLSRoute"}
    template:
      apiVersion: gateway.networking.k8s.io/v1alpha2
      kind: TLSRoute
      metadata:
        name: ${schema.metadata.name}
      spec:
        parentRefs: ${schema.spec.parentGateways.map(gw, {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw, "namespace": "home"})}
        hostnames: ${schema.spec.hostnames}
        rules:
        - backendRefs:
          - group: ""
            kind: Service
            name: ${schema.spec.backendRef.name}
            port: ${schema.spec.backendRef.port}
```

Note: The `parentGateways` field uses short gateway names (`ts`, `private`, `public`). The CEL `map()` function expands each to a full parentRef. The gateway names must match the actual Gateway resource names in the `home` namespace.

- [ ] **Step 2: Add to rgd kustomization**

Add `- ./app-route.yaml` to `clusters/common/apps/kro/rgd/kustomization.yaml`.

- [ ] **Step 3: Verify CRD registers**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get crd approutes.network.keiretsu.ts.net
```

- [ ] **Step 4: Test with a dry-run HTTPRoute**

```bash
cat <<'EOF' | kubectl --context ottawa-k8s-operator.keiretsu.ts.net apply -f -
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: AppRoute
metadata:
  name: test-route
  namespace: default
spec:
  kind: HTTPRoute
  backendRef:
    name: nginx
    port: 80
  parentGateways:
    - ts
    - private
  hostnames:
    - "test.killinit.cc"
  pathPrefix: /
  homerName: "Test App"
  homerSubtitle: "Testing"
  homerLogo: ""
  homerKeywords: "test"
  homerService: "Test"
  homerServiceIcon: "fas fa-vial"
EOF
```

Verify HTTPRoute created:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get httproute test-route -n default -o yaml
```

Expected: HTTPRoute with 2 parentRefs (ts, private in home namespace), hostname `test.killinit.cc`, and homer annotations.

- [ ] **Step 5: Clean up test**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net delete approute test-route -n default
```

- [ ] **Step 6: Commit**

```bash
git add clusters/common/apps/kro/rgd/app-route.yaml clusters/common/apps/kro/rgd/kustomization.yaml
git commit -m "feat(kro): add AppRoute RGD for Gateway API route generation"
```

---

### Task 5: GSLBEndpoint RGD

**Files:**
- Create: `clusters/common/apps/kro/rgd/gslb-endpoint.yaml`
- Modify: `clusters/common/apps/kro/rgd/kustomization.yaml`

- [ ] **Step 1: Create the RGD**

```yaml
# clusters/common/apps/kro/rgd/gslb-endpoint.yaml
---
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: gslbendpoint
  annotations:
    kro.run/allow-breaking-changes: "true"
spec:
  schema:
    group: network.keiretsu.ts.net
    apiVersion: v1alpha1
    kind: GSLBEndpoint
    scope: Namespaced
    spec:
      httpRouteRef:
        name: "string | required=true"
        namespace: "string | required=true"
      strategy: "string | default=roundRobin"
      dnsTtlSeconds: "integer | default=60"
      weights:
        ottawa: "integer | default=33"
        robbinsdale: "integer | default=33"
        stpetersburg: "integer | default=34"
    status:
      ready: ${gslb.metadata.name != ""}

  resources:
  - id: gslb
    template:
      apiVersion: k8gb.absa.oss/v1beta1
      kind: Gslb
      metadata:
        name: ${schema.metadata.name}
      spec:
        resourceRef:
          kind: HTTPRoute
          name: ${schema.spec.httpRouteRef.name}
          namespace: ${schema.spec.httpRouteRef.namespace}
        strategy:
          type: ${schema.spec.strategy}
          dnsTtlSeconds: ${schema.spec.dnsTtlSeconds}
          weight:
            ottawa: ${schema.spec.weights.ottawa}
            robbinsdale: ${schema.spec.weights.robbinsdale}
            stpetersburg: ${schema.spec.weights.stpetersburg}
```

- [ ] **Step 2: Add to rgd kustomization**

Add `- ./gslb-endpoint.yaml` to `clusters/common/apps/kro/rgd/kustomization.yaml`.

- [ ] **Step 3: Verify CRD registers**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get crd gslbendpoints.network.keiretsu.ts.net
```

- [ ] **Step 4: Commit**

```bash
git add clusters/common/apps/kro/rgd/gslb-endpoint.yaml clusters/common/apps/kro/rgd/kustomization.yaml
git commit -m "feat(kro): add GSLBEndpoint RGD wrapper for k8gb Gslb"
```

---

## Phase 3: Storage — StorageStack

### Task 6: StorageStack RGD

This is the most complex RGD due to the probe Job auto-detection and dependency chain.

**Files:**
- Create: `clusters/common/apps/kro/rgd/storage-stack.yaml`
- Modify: `clusters/common/apps/kro/rgd/kustomization.yaml`

- [ ] **Step 1: Create the RGD**

```yaml
# clusters/common/apps/kro/rgd/storage-stack.yaml
---
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: storagestack
  annotations:
    kro.run/allow-breaking-changes: "true"
spec:
  schema:
    group: storage.keiretsu.ts.net
    apiVersion: v1alpha1
    kind: StorageStack
    scope: Namespaced
    spec:
      # PVC
      name: "string | required=true"
      size: "string | default=5Gi"
      storageClass: "string | default=ceph-block-replicated-nvme"
      accessMode: "string | default=ReadWriteOnce"

      # Garage bucket
      bucketCreate: "boolean | default=false"
      bucketAlias: "string | default=keiretsu"
      bucketQuota: "string | default=100Gi"

      # S3 path
      s3Endpoint: "string | required=true"
      s3Location: "string | required=true"
      s3Path: "string | required=true"

      # Backup
      schedule: "string | required=true"
      copyMethod: "string | default=Snapshot"
      snapshotClass: "string | default=csi-rbdplugin-snapclass"
      pruneIntervalDays: "integer | default=14"
      resticPassword: "string | required=true"

      # Retention
      retainHourly: "integer | default=1"
      retainDaily: "integer | default=3"
      retainWeekly: "integer | default=4"
      retainMonthly: "integer | default=2"
      retainYearly: "integer | default=1"

      # Restore behavior
      restoreMode: "string | default=auto"
      restorePaused: "boolean | default=true"

    status:
      pvcName: ${schema.spec.name}
      secretName: ${"restic-" + schema.spec.name}
      ready: ${garageKey.metadata.name != ""}

  resources:

  # 1. GarageKey → Secret
  - id: garageKey
    template:
      apiVersion: garage.rajsingh.info/v1alpha1
      kind: GarageKey
      metadata:
        name: ${"volsync-" + schema.spec.name + "-key"}
      spec:
        clusterRef:
          name: garage
          namespace: garage
        name: ${"StorageStack " + schema.spec.name + " Key"}
        secretTemplate:
          name: ${"restic-" + schema.spec.name}
          namespace: ${schema.metadata.namespace}
          accessKeyIdKey: AWS_ACCESS_KEY_ID
          secretAccessKeyKey: AWS_SECRET_ACCESS_KEY
          includeEndpoint: false
          includeRegion: false
          additionalData:
            RESTIC_REPOSITORY: ${"s3:http://" + schema.spec.s3Endpoint + "/" + schema.spec.bucketAlias + "/" + schema.spec.s3Location + "/" + schema.spec.s3Path}
            RESTIC_PASSWORD: ${schema.spec.resticPassword}
        bucketPermissions:
        - globalAlias: ${schema.spec.bucketAlias}
          read: true
          write: true

  # 2. GarageBucket (optional)
  - id: garageBucket
    includeWhen:
    - ${schema.spec.bucketCreate}
    template:
      apiVersion: garage.rajsingh.info/v1alpha1
      kind: GarageBucket
      metadata:
        name: ${schema.spec.bucketAlias}
      spec:
        clusterRef:
          name: garage
          namespace: garage
        globalAlias: ${schema.spec.bucketAlias}
        quotas:
          maxSize: ${schema.spec.bucketQuota}
        keyPermissions:
        - keyRef: ${"volsync-" + schema.spec.name + "-key"}

  # 3. Probe Job — checks if restic repo has snapshots
  - id: probeJob
    includeWhen:
    - ${schema.spec.restoreMode == "auto"}
    template:
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: ${"probe-" + schema.spec.name}
      spec:
        ttlSecondsAfterFinished: 300
        backoffLimit: 0
        template:
          spec:
            restartPolicy: Never
            containers:
            - name: probe
              image: restic/restic:0.18.0
              command:
              - /bin/sh
              - -c
              - |
                if restic snapshots --json --latest 1 2>/dev/null | grep -q '"time"'; then
                  echo '{"data":{"hasBackup":"true"}}' > /dev/termination-log
                else
                  echo '{"data":{"hasBackup":"false"}}' > /dev/termination-log
                fi
              envFrom:
              - secretRef:
                  name: ${garageKey.spec.secretTemplate.name}
    readyWhen:
    - ${probeJob.status.?succeeded > 0 || probeJob.status.?failed > 0}

  # 4a. Restore path — ReplicationDestination + PVC with dataSourceRef
  #     When: mode=restore OR (mode=auto AND probe found backups)
  - id: replicationDestinationSnapshot
    includeWhen:
    - ${(schema.spec.restoreMode == "restore") || (schema.spec.restoreMode == "auto" && schema.spec.copyMethod == "Snapshot")}
    template:
      apiVersion: volsync.backube/v1alpha1
      kind: ReplicationDestination
      metadata:
        name: ${schema.spec.name}
      spec:
        trigger:
          manual: first
        paused: ${schema.spec.restorePaused}
        restic:
          repository: ${"restic-" + schema.spec.name}
          accessModes:
          - ${schema.spec.accessMode}
          copyMethod: Snapshot
          capacity: ${schema.spec.size}
          storageClassName: ${schema.spec.storageClass}
          volumeSnapshotClassName: ${schema.spec.snapshotClass}

  - id: pvcSnapshot
    includeWhen:
    - ${(schema.spec.restoreMode == "restore" && schema.spec.copyMethod == "Snapshot") || (schema.spec.restoreMode == "auto" && schema.spec.copyMethod == "Snapshot")}
    template:
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: ${schema.spec.name}
      spec:
        accessModes:
        - ${schema.spec.accessMode}
        resources:
          requests:
            storage: ${schema.spec.size}
        dataSourceRef:
          kind: ReplicationDestination
          apiGroup: volsync.backube
          name: ${replicationDestinationSnapshot.metadata.name}

  # 4b. Direct restore path
  - id: replicationDestinationDirect
    includeWhen:
    - ${(schema.spec.restoreMode == "restore" || schema.spec.restoreMode == "auto") && schema.spec.copyMethod == "Direct"}
    template:
      apiVersion: volsync.backube/v1alpha1
      kind: ReplicationDestination
      metadata:
        name: ${schema.spec.name}
      spec:
        trigger:
          manual: first
        paused: ${schema.spec.restorePaused}
        restic:
          repository: ${"restic-" + schema.spec.name}
          destinationPVC: ${schema.spec.name}
          copyMethod: Direct

  - id: pvcDirect
    includeWhen:
    - ${(schema.spec.restoreMode == "restore" || schema.spec.restoreMode == "auto") && schema.spec.copyMethod == "Direct"}
    template:
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: ${schema.spec.name}
      spec:
        accessModes:
        - ${schema.spec.accessMode}
        resources:
          requests:
            storage: ${schema.spec.size}
        storageClassName: ${schema.spec.storageClass}

  # 4c. Fresh PVC (backup-only mode — no restore)
  - id: pvcFresh
    includeWhen:
    - ${schema.spec.restoreMode == "backup-only"}
    template:
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: ${schema.spec.name}
      spec:
        accessModes:
        - ${schema.spec.accessMode}
        resources:
          requests:
            storage: ${schema.spec.size}
        storageClassName: ${schema.spec.storageClass}

  # 5. ReplicationSource (backup — always created)
  - id: replicationSource
    template:
      apiVersion: volsync.backube/v1alpha1
      kind: ReplicationSource
      metadata:
        name: ${schema.spec.name}
      spec:
        sourcePVC: ${schema.spec.name}
        trigger:
          schedule: ${schema.spec.schedule}
        restic:
          pruneIntervalDays: ${schema.spec.pruneIntervalDays}
          repository: ${"restic-" + schema.spec.name}
          retain:
            hourly: ${schema.spec.retainHourly}
            daily: ${schema.spec.retainDaily}
            weekly: ${schema.spec.retainWeekly}
            monthly: ${schema.spec.retainMonthly}
            yearly: ${schema.spec.retainYearly}
          copyMethod: Direct
```

**Important implementation note:** The probe Job writes its result to `/dev/termination-log`. KRO can read this via `${probeJob.status.?containerStatuses[0].?state.?terminated.?message}`. However, KRO's `includeWhen` is evaluated at RGD compile time, not dynamically based on Job output. The probe Job pattern needs validation — if KRO doesn't support dynamic branching based on Job results, we fall back to explicit `restoreMode` (backup-only or restore) and the probe serves as documentation only.

**Fallback approach:** If dynamic branching doesn't work in KRO, the `restoreMode` field becomes the manual switch:
- `backup-only` (default for new apps) — creates fresh PVC
- `restore` — creates ReplicationDestination + PVC with dataSourceRef
- `auto` falls back to `backup-only` behavior

This is still better than the old `freshInstall` toggle because the naming is clearer.

- [ ] **Step 2: Add to rgd kustomization**

Add `- ./storage-stack.yaml` to `clusters/common/apps/kro/rgd/kustomization.yaml`.

- [ ] **Step 3: Verify CRD registers**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get crd storagestacks.storage.keiretsu.ts.net
```

- [ ] **Step 4: Test with backup-only mode**

```bash
cat <<'EOF' | kubectl --context ottawa-k8s-operator.keiretsu.ts.net apply -f -
apiVersion: storage.keiretsu.ts.net/v1alpha1
kind: StorageStack
metadata:
  name: test-storage
  namespace: default
spec:
  name: test-storage
  size: 1Gi
  storageClass: ceph-block-replicated
  s3Endpoint: "ottawa-garage.keiretsu.ts.net:3900"
  s3Location: "ottawa"
  s3Path: "test/storage-stack"
  schedule: "0 6 * * *"
  resticPassword: "test-password"
  restoreMode: backup-only
EOF
```

Verify resources created:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get garagekey,pvc,replicationsource -n default | grep test-storage
```

Expected: GarageKey, PVC (empty, no dataSourceRef), and ReplicationSource all created.

- [ ] **Step 5: Clean up test**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net delete storagestack test-storage -n default
```

- [ ] **Step 6: Validate probe Job behavior (if auto mode)**

If the probe Job pattern works in KRO, test with `restoreMode: auto`:

```bash
cat <<'EOF' | kubectl --context ottawa-k8s-operator.keiretsu.ts.net apply -f -
apiVersion: storage.keiretsu.ts.net/v1alpha1
kind: StorageStack
metadata:
  name: test-auto
  namespace: default
spec:
  name: test-auto
  size: 1Gi
  s3Endpoint: "ottawa-garage.keiretsu.ts.net:3900"
  s3Location: "ottawa"
  s3Path: "test/auto-detect"
  schedule: "0 6 * * *"
  resticPassword: "test-password"
  restoreMode: auto
EOF
```

Check if the probe Job runs:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get jobs -n default | grep probe-test-auto
```

If the Job runs and KRO doesn't branch dynamically, update the RGD to remove the `auto` mode and document the limitation. Change default `restoreMode` to `backup-only`.

- [ ] **Step 7: Clean up and commit**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net delete storagestack test-auto -n default 2>/dev/null
git add clusters/common/apps/kro/rgd/storage-stack.yaml clusters/common/apps/kro/rgd/kustomization.yaml
git commit -m "feat(kro): add StorageStack RGD with volsync backup/restore lifecycle"
```

---

## Phase 4: Composite — KeiretsuApp

### Task 7: KeiretsuApp RGD

**Files:**
- Create: `clusters/common/apps/kro/rgd/keiretsu-app.yaml`
- Modify: `clusters/common/apps/kro/rgd/kustomization.yaml`

- [ ] **Step 1: Create the RGD**

This is the composite that chains all primitives. Start with a minimal version (Deployment + Service + ServiceIngress) and extend.

```yaml
# clusters/common/apps/kro/rgd/keiretsu-app.yaml
---
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: keiretsuapp
  annotations:
    kro.run/allow-breaking-changes: "true"
spec:
  schema:
    group: apps.keiretsu.ts.net
    apiVersion: v1alpha1
    kind: KeiretsuApp
    scope: Namespaced
    spec:
      # Deployment
      name: "string | required=true"
      image: "string | required=true"
      port: "integer | required=true"
      replicas: "integer | default=1"
      env:
        type: "[]EnvVar"
        items:
          name: "string | required=true"
          value: "string | required=true"

      # Ingress (optional)
      ingressEnabled: "boolean | default=false"
      ingressHostname: "string"
      ingressTags: "string | default=tag:k8s"
      ingressProxyGroup: "string | default=common-ingress"
      ingressGlobalEnabled: "boolean | default=false"
      ingressGlobalHostname: "string"
      ingressGlobalTags: "string | default=tag:k8s"

      # Storage (optional)
      storageEnabled: "boolean | default=false"
      storageSize: "string | default=5Gi"
      storageClass: "string | default=ceph-block-replicated-nvme"
      storageS3Endpoint: "string"
      storageS3Location: "string"
      storageS3Path: "string"
      storageSchedule: "string"
      storageResticPassword: "string"
      storageRestoreMode: "string | default=backup-only"

    status:
      ready: ${deployment.status.?readyReplicas > 0}
      serviceIP: ${service.spec.clusterIP}

  resources:
  # Deployment
  - id: deployment
    template:
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ${schema.spec.name}
      spec:
        replicas: ${schema.spec.replicas}
        selector:
          matchLabels:
            app.kubernetes.io/name: ${schema.spec.name}
        template:
          metadata:
            labels:
              app.kubernetes.io/name: ${schema.spec.name}
          spec:
            containers:
            - name: ${schema.spec.name}
              image: ${schema.spec.image}
              ports:
              - containerPort: ${schema.spec.port}
              env: ${schema.spec.env}

  # Service
  - id: service
    template:
      apiVersion: v1
      kind: Service
      metadata:
        name: ${schema.spec.name}
      spec:
        selector:
          app.kubernetes.io/name: ${schema.spec.name}
        ports:
        - name: http
          port: ${schema.spec.port}
          targetPort: ${schema.spec.port}

  # ServiceIngress (optional)
  - id: serviceIngress
    includeWhen:
    - ${schema.spec.ingressEnabled}
    template:
      apiVersion: network.keiretsu.ts.net/v1alpha1
      kind: ServiceIngress
      metadata:
        name: ${schema.spec.name}
      spec:
        selector:
          app.kubernetes.io/name: ${schema.spec.name}
        ports:
        - name: http
          port: ${schema.spec.port}
        hostname: ${schema.spec.ingressHostname}
        tags: ${schema.spec.ingressTags}
        proxyGroup: ${schema.spec.ingressProxyGroup}
        global:
          enabled: ${schema.spec.ingressGlobalEnabled}
          hostname: ${schema.spec.ingressGlobalHostname}
          tags: ${schema.spec.ingressGlobalTags}
          ports:
          - name: http
            port: ${schema.spec.port}

  # StorageStack (optional)
  - id: storageStack
    includeWhen:
    - ${schema.spec.storageEnabled}
    template:
      apiVersion: storage.keiretsu.ts.net/v1alpha1
      kind: StorageStack
      metadata:
        name: ${schema.spec.name + "-config"}
      spec:
        name: ${schema.spec.name + "-config"}
        size: ${schema.spec.storageSize}
        storageClass: ${schema.spec.storageClass}
        s3Endpoint: ${schema.spec.storageS3Endpoint}
        s3Location: ${schema.spec.storageS3Location}
        s3Path: ${schema.spec.storageS3Path}
        schedule: ${schema.spec.storageSchedule}
        resticPassword: ${schema.spec.storageResticPassword}
        restoreMode: ${schema.spec.storageRestoreMode}
```

Note: This is the initial version. The deployment spec, routes (forEach), and GSLB chaining will be added incrementally as the primitives are validated. KRO chaining (using one RGD's CRD as a resource in another) is the key pattern here — KeiretsuApp creates `ServiceIngress` and `StorageStack` instances.

- [ ] **Step 2: Add to rgd kustomization**

Add `- ./keiretsu-app.yaml` to `clusters/common/apps/kro/rgd/kustomization.yaml`.

- [ ] **Step 3: Verify CRD registers**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get crd keiretsuapps.apps.keiretsu.ts.net
```

- [ ] **Step 4: Test with minimal instance**

```bash
cat <<'EOF' | kubectl --context ottawa-k8s-operator.keiretsu.ts.net apply -f -
apiVersion: apps.keiretsu.ts.net/v1alpha1
kind: KeiretsuApp
metadata:
  name: test-app
  namespace: default
spec:
  name: test-app
  image: nginx:alpine
  port: 80
  replicas: 1
  env: []
  ingressEnabled: false
  storageEnabled: false
EOF
```

Verify Deployment + Service created:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get deploy,svc -n default | grep test-app
```

Expected: Deployment `test-app` and Service `test-app` exist.

- [ ] **Step 5: Clean up test**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net delete keiretsuapp test-app -n default
```

- [ ] **Step 6: Commit**

```bash
git add clusters/common/apps/kro/rgd/keiretsu-app.yaml clusters/common/apps/kro/rgd/kustomization.yaml
git commit -m "feat(kro): add KeiretsuApp composite RGD chaining ServiceIngress + StorageStack"
```

---

## Phase 5: ArgoCD Infrastructure

### Task 8: Directory Structure + ApplicationSets

**Files:**
- Create: `clusters/apps/.gitkeep`
- Create: `clusters/talos-ottawa/apps/argocd/apps/keiretsu-apps.yaml`
- Create: `clusters/talos-ottawa/apps/argocd/apps/keiretsu-egress.yaml`
- Create: `clusters/talos-ottawa/apps/argocd/apps/keiretsu-gslb.yaml`

- [ ] **Step 1: Create the apps directory**

```bash
mkdir -p clusters/apps
touch clusters/apps/.gitkeep
```

- [ ] **Step 2: Create keiretsu-apps ApplicationSet**

```yaml
# clusters/talos-ottawa/apps/argocd/apps/keiretsu-apps.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: keiretsu-apps
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  tier: app-host
          - git:
              repoURL: https://github.com/keiretsu-labs/kubernetes-manifests
              revision: HEAD
              directories:
                - path: clusters/apps/*/app
  template:
    metadata:
      name: "keiretsu-{{.path.basename}}-{{.name}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/keiretsu-labs/kubernetes-manifests
        targetRevision: HEAD
        path: "{{.path.path}}"
      destination:
        name: "{{.name}}"
        namespace: "{{.path.basename}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

- [ ] **Step 3: Create keiretsu-egress ApplicationSet**

```yaml
# clusters/talos-ottawa/apps/argocd/apps/keiretsu-egress.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: keiretsu-egress
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  argocd.argoproj.io/secret-type: cluster
          - git:
              repoURL: https://github.com/keiretsu-labs/kubernetes-manifests
              revision: HEAD
              directories:
                - path: clusters/apps/*/egress
  template:
    metadata:
      name: "egress-{{.path.basename}}-{{.name}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/keiretsu-labs/kubernetes-manifests
        targetRevision: HEAD
        path: "{{.path.path}}"
      destination:
        name: "{{.name}}"
        namespace: "{{.path.basename}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

- [ ] **Step 4: Create keiretsu-gslb ApplicationSet**

```yaml
# clusters/talos-ottawa/apps/argocd/apps/keiretsu-gslb.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: keiretsu-gslb
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  has-gslb: "true"
          - git:
              repoURL: https://github.com/keiretsu-labs/kubernetes-manifests
              revision: HEAD
              directories:
                - path: clusters/apps/*/gslb
  template:
    metadata:
      name: "gslb-{{.path.basename}}-{{.name}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/keiretsu-labs/kubernetes-manifests
        targetRevision: HEAD
        path: "{{.path.path}}"
      destination:
        name: "{{.name}}"
        namespace: "{{.path.basename}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

- [ ] **Step 5: Verify ArgoCD cluster labels**

Check that clusters have the required labels:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster --show-labels
```

If `tier=app-host` and `has-gslb=true` labels are missing, add them to the cluster secrets.

- [ ] **Step 6: Commit**

```bash
git add clusters/apps/ clusters/talos-ottawa/apps/argocd/apps/keiretsu-*.yaml
git commit -m "feat(argocd): add ApplicationSets for Keiretsu CRD placement"
```

---

## Phase 6: Migration — Garage as First Service

### Task 9: Migrate Garage to Keiretsu CRDs

This is the proof-of-concept: replace garage's manual `service-ts.yaml` and `egress.yaml` with ServiceIngress + ServiceEgress CRD instances.

**Files:**
- Create: `clusters/apps/garage/app/ingress.yaml`
- Create: `clusters/apps/garage/app/kustomization.yaml`
- Create: `clusters/apps/garage/egress/egress.yaml`
- Create: `clusters/apps/garage/egress/kustomization.yaml`

- [ ] **Step 1: Create ServiceIngress instance for garage**

```yaml
# clusters/apps/garage/app/ingress.yaml
---
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: ServiceIngress
metadata:
  name: garage
  namespace: garage
spec:
  selector:
    app.kubernetes.io/name: garage
    app.kubernetes.io/instance: garage
  ports:
    - name: s3-api
      port: 3900
    - name: rpc
      port: 3901
    - name: s3-web
      port: 3902
    - name: admin
      port: 3903
  hostname: "${LOCATION}-garage"
  tags: "tag:k8s,tag:${LOCATION}"
  proxyGroup: common-ingress
  publishNotReadyAddresses: true
  global:
    enabled: true
    hostname: "garage"
    tags: "tag:k8s"
    ports:
      - name: s3-api
        port: 3900
      - name: s3-web
        port: 3902
      - name: admin
        port: 3903
    proxyGroup: common-ingress
```

- [ ] **Step 2: Create app kustomization**

```yaml
# clusters/apps/garage/app/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ingress.yaml
```

- [ ] **Step 3: Create ServiceEgress instance for garage**

```yaml
# clusters/apps/garage/egress/egress.yaml
---
apiVersion: network.keiretsu.ts.net/v1alpha1
kind: ServiceEgress
metadata:
  name: garage
  namespace: garage
spec:
  endpoints:
    - name: ottawa-garage
      fqdn: ottawa-garage.keiretsu.ts.net
      ports:
        - name: s3-api
          port: 3900
        - name: rpc
          port: 3901
        - name: s3-web
          port: 3902
        - name: admin
          port: 3903
    - name: robbinsdale-garage
      fqdn: robbinsdale-garage.keiretsu.ts.net
      ports:
        - name: s3-api
          port: 3900
        - name: rpc
          port: 3901
        - name: s3-web
          port: 3902
        - name: admin
          port: 3903
    - name: stpetersburg-garage
      fqdn: stpetersburg-garage.keiretsu.ts.net
      ports:
        - name: s3-api
          port: 3900
        - name: rpc
          port: 3901
        - name: s3-web
          port: 3902
        - name: admin
          port: 3903
  global:
    enabled: true
    name: garage-global
    fqdn: garage.keiretsu.ts.net
    ports:
      - name: s3-api
        port: 3900
  proxyGroup: common-egress
```

- [ ] **Step 4: Create egress kustomization**

```yaml
# clusters/apps/garage/egress/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - egress.yaml
```

- [ ] **Step 5: Deploy and verify (DO NOT remove old resources yet)**

Commit and push. Wait for ArgoCD to sync. Then verify the new CRD-managed services exist alongside the old manual ones:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get svc -n garage
```

Expected: Both old (`garage-ts`, `garage-global-ts`, `ottawa-garage`, etc.) and new CRD-managed services visible.

- [ ] **Step 6: Verify cross-cluster connectivity via new services**

Test that the CRD-managed services route correctly:

```bash
ADMIN_TOKEN=$(kubectl --context ottawa-k8s-operator.keiretsu.ts.net get secret garage-admin-token -n garage -o jsonpath='{.data.admin-token}' | base64 -d)
curl -s --connect-timeout 5 -H "Authorization: Bearer $ADMIN_TOKEN" "http://garage.keiretsu.ts.net:3903/v2/GetClusterStatus" | python3 -m json.tool | head -10
```

Expected: Cluster status response showing all 3 nodes.

- [ ] **Step 7: Commit (new CRDs alongside old)**

```bash
git add clusters/apps/garage/
git commit -m "feat(garage): add ServiceIngress + ServiceEgress CRD instances"
```

- [ ] **Step 8: Remove old manual resources (separate commit)**

Once verified working, remove the old manual YAML:
- `clusters/common/apps/garage/app/service-ts.yaml`
- `clusters/common/apps/garage/app/egress.yaml`

Update `clusters/common/apps/garage/app/kustomization.yaml` to remove references to these files.

**IMPORTANT:** Do this in a separate commit so it's easy to revert if something breaks.

```bash
git rm clusters/common/apps/garage/app/service-ts.yaml clusters/common/apps/garage/app/egress.yaml
# Edit kustomization.yaml to remove the two references
git add clusters/common/apps/garage/app/kustomization.yaml
git commit -m "refactor(garage): remove manual service-ts and egress, now managed by Keiretsu CRDs"
```

- [ ] **Step 9: Final verification**

After Flux prunes the old resources, verify that only the CRD-managed services remain and cross-cluster connectivity still works:

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get svc -n garage
curl -s --connect-timeout 5 -H "Authorization: Bearer $ADMIN_TOKEN" "http://garage.keiretsu.ts.net:3903/v2/GetClusterStatus" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'{n[\"role\"][\"zone\"]}: isUp={n[\"isUp\"]}') for n in d['nodes']]"
```

Expected: All 3 nodes up, only CRD-managed services in the namespace.

---

## Post-Implementation

### Task 10: Clean up experimental RGDs

Once the new CRDs are validated with the garage migration, remove the old experimental RGDs:

- [ ] **Step 1: Remove old RGD files**

```bash
git rm clusters/common/apps/kro/rgd/arrapp.yaml
git rm clusters/common/apps/kro/rgd/qbapp.yaml
git rm clusters/common/apps/kro/rgd/gluetunapp.yaml
git rm clusters/common/apps/kro/rgd/floatingapp.yaml
git rm clusters/common/apps/kro/rgd/meshegress.yaml
git rm clusters/common/apps/kro/rgd/volsyncbackup.yaml
git rm clusters/common/apps/kro/rgd/app.yaml
```

- [ ] **Step 2: Update rgd kustomization**

Replace `clusters/common/apps/kro/rgd/kustomization.yaml` contents with only the new RGDs:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./service-ingress.yaml
  - ./service-egress.yaml
  - ./storage-stack.yaml
  - ./app-route.yaml
  - ./gslb-endpoint.yaml
  - ./keiretsu-app.yaml
  - ./backupverify.yaml
```

- [ ] **Step 3: Verify no existing instances depend on old RGDs**

```bash
for ctx in ottawa-k8s-operator.keiretsu.ts.net robbinsdale-k8s-operator.keiretsu.ts.net; do
  echo "=== $ctx ==="
  kubectl --context $ctx get arrapp,qbapp,gluetunapp,floatingapp,meshegress,volsyncbackup,app -A 2>/dev/null
done
```

If any instances exist, migrate them first before removing the RGDs.

- [ ] **Step 4: Commit**

```bash
git add clusters/common/apps/kro/rgd/
git commit -m "chore(kro): remove experimental RGDs, replaced by Keiretsu CRD system"
```
