# Garage Web Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a shared in-cluster nginx `proxy_cache` in front of Garage's web endpoint so static sites are served snappily with a tiny RAM footprint and ~10s change propagation.

**Architecture:** One `garage-web-cache` Deployment + Service + nginx ConfigMap lives in `kubernetes/apps/base/garage/garage/` — deployed to all three clusters by the existing per-location `garage` pointers. The Envoy `public` gateway HTTPRoutes flip their `backendRefs` from `garage-gateway:3902` to `garage-web-cache:80`. nginx caches on disk (bounded, low RAM), revalidates against Garage's ETag on a short TTL, and collapses concurrent misses.

**Tech Stack:** Flux CD (Kustomize), Gateway API (Envoy Gateway), nginx (`nginxinc/nginx-unprivileged`), Garage v2 web endpoint.

## Global Constraints

- **No unit-test framework.** The per-task guard is a `flate` render (`make test` / `make test-talos-ottawa`) that must exit 0. There is no "write a failing test first" — the render + a final live validation are the tests.
- **GitOps only.** All changes land in Git; do not `kubectl apply` manifests (Flux reconciles them). Live validation may `kubectl get`/`curl`/`kubectl rollout`, never `apply`.
- **Commit style:** local user only, no Claude/AI branding in messages (per repo rules).
- **Push after each commit** to `worktree-garage-cdn`.
- **Namespace:** all new resources are in the `garage` namespace (set by `base/garage/garage/kustomization.yaml`'s `namespace: garage`). Do not add `namespace:` to the manifests.
- **`${COMMON_DOMAIN}`** is `keiretsu.top`; substituted by Flux — leave `${COMMON_DOMAIN}` literal in manifests.
- **Freshness knobs (from spec):** edge TTL `10s` revalidated; browser `Cache-Control: public, max-age=60, stale-while-revalidate=30`.

---

### Task 1: Add the `garage-web-cache` cache workload

**Files:**
- Create: `kubernetes/apps/base/garage/garage/web-cache.conf` (nginx config, generated into a ConfigMap)
- Create: `kubernetes/apps/base/garage/garage/web-cache.yaml` (Deployment + Service)
- Modify: `kubernetes/apps/base/garage/garage/kustomization.yaml` (add resource + configMapGenerator)

**Interfaces:**
- Produces: Service `garage-web-cache` in namespace `garage`, port `80` → containerPort `8080`. Later tasks point HTTPRoute `backendRefs` at `garage-web-cache:80`.
- Consumes: existing operator-created Service `garage-gateway` (port `3902`) in the `garage` namespace.

- [ ] **Step 1: Write the nginx cache config**

Create `kubernetes/apps/base/garage/garage/web-cache.conf`:

```nginx
# Reverse-proxy cache in front of Garage's web endpoint (garage-gateway:3902).
# Disk-backed cache: only the keys_zone (~5MB) lives in RAM; bodies on disk.
proxy_cache_path /var/cache/nginx/web levels=1:2 keys_zone=web:5m
                 max_size=2g inactive=1h use_temp_path=off;

# Runtime DNS so a briefly-absent garage-gateway Service doesn't crashloop nginx.
resolver kube-dns.kube-system.svc.cluster.local valid=30s ipv6=off;

server {
    listen 8080;
    server_name _;

    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    location / {
        # Variable upstream forces per-request DNS resolution via resolver above.
        set $garage garage-gateway.garage.svc.cluster.local:3902;
        proxy_pass http://$garage;

        # Preserve the bucket host the gateway already rewrote (e.g. raj-assistant-web.keiretsu.top).
        proxy_set_header Host $host;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        proxy_cache web;
        proxy_cache_key "$host$request_uri";
        proxy_cache_valid 200 301 302 10s;   # short edge TTL -> ~10s change propagation
        proxy_cache_valid 404 5s;
        proxy_cache_revalidate on;           # conditional GET on expiry -> cheap 304s
        proxy_cache_lock on;                 # collapse concurrent misses -> single origin fetch
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;    # serve stale instantly, refresh in background

        add_header X-Cache-Status $upstream_cache_status always;
    }
}
```

- [ ] **Step 2: Write the Deployment + Service**

Create `kubernetes/apps/base/garage/garage/web-cache.yaml`:

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: garage-web-cache
  labels:
    app.kubernetes.io/name: garage-web-cache
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: garage-web-cache
  template:
    metadata:
      labels:
        app.kubernetes.io/name: garage-web-cache
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        runAsGroup: 101
        fsGroup: 101            # make the emptyDir group-writable by the nginx uid
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
              readOnly: true
            - name: cache
              mountPath: /var/cache/nginx
            - name: tmp
              mountPath: /tmp          # nginx-unprivileged writes its pid here; needed under readOnlyRootFilesystem
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 20
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            readOnlyRootFilesystem: true
      volumes:
        - name: config
          configMap:
            name: garage-web-cache-nginx
        - name: cache
          emptyDir: {}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: garage-web-cache
  labels:
    app.kubernetes.io/name: garage-web-cache
spec:
  selector:
    app.kubernetes.io/name: garage-web-cache
  ports:
    - name: http
      port: 80
      targetPort: 8080
```

Note: `readOnlyRootFilesystem: true` is satisfied by the two writable `emptyDir` mounts — `/var/cache/nginx` (cache) and `/tmp` (nginx-unprivileged writes its pid + temp there). If nginx still fails to start on a read-only path, check the pod logs for the exact path and add another `emptyDir` mount for it.

- [ ] **Step 3: Wire into the kustomization**

Modify `kubernetes/apps/base/garage/garage/kustomization.yaml`. Add `web-cache.yaml` to `resources` (after `httproute-web.yaml`), and add a second `configMapGenerator` entry that opts OUT of the global `disableNameSuffixHash: true` so nginx config edits roll the pods:

```yaml
resources:
  - admin-token.yaml
  - egress.yaml
  - reference-grants.yaml
  - service-ts.yaml
  - service-ts-gateway.yaml
  - garagecluster.yaml
  - rpc-secret.yaml
  - httproute-s3.yaml
  - httproute-web.yaml
  - web-cache.yaml
  - referencegrant-agent-web.yaml
  - referencegrant-bhaiya-web.yaml
  - probes.yaml
  - prometheusrule.yaml
  - grafana-dashboard.yaml
configMapGenerator:
  - name: garage-grafana-dashboard
    files:
      - dashboard.json
    options:
      labels:
        grafana_dashboard: "1"
      annotations:
        grafana_folder: garage
  - name: garage-web-cache-nginx
    files:
      - default.conf=web-cache.conf
    options:
      disableNameSuffixHash: false
generatorOptions:
  disableNameSuffixHash: true
```

The Deployment references `garage-web-cache-nginx` by base name; kustomize rewrites the volume's `configMap.name` to the hashed name automatically, so a config change produces a new ConfigMap name and rolls the Deployment.

- [ ] **Step 4: Render-test**

Run: `make test-talos-ottawa`
Expected: exits 0; the rendered output includes `Deployment/garage-web-cache`, `Service/garage-web-cache`, and a `ConfigMap/garage-web-cache-nginx-<hash>` in the `garage` namespace, with the Deployment volume referencing the hashed ConfigMap name.

- [ ] **Step 5: Commit and push**

```bash
git add kubernetes/apps/base/garage/garage/web-cache.conf \
        kubernetes/apps/base/garage/garage/web-cache.yaml \
        kubernetes/apps/base/garage/garage/kustomization.yaml
git commit -m "garage: add in-cluster web cache in front of garage web endpoint"
git push
```

---

### Task 2: Route cdn-site through the cache

**Files:**
- Modify: `kubernetes/components/cdn-site/httproute.yaml:32-42` (Cache-Control value + backendRefs)

**Interfaces:**
- Consumes: Service `garage-web-cache:80` (Task 1).

- [ ] **Step 1: Point the backend at the cache and lower the browser TTL**

In `kubernetes/components/cdn-site/httproute.yaml`, change the `Cache-Control` value and the `backendRefs` block. Replace:

```yaml
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            add:
              - name: Cache-Control
                value: "public, max-age=3600"
      backendRefs:
        - group: ""
          kind: Service
          name: garage-gateway
          port: 3902
          weight: 1
```

with:

```yaml
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            add:
              - name: Cache-Control
                value: "public, max-age=60, stale-while-revalidate=30"
      backendRefs:
        - group: ""
          kind: Service
          name: garage-web-cache
          port: 80
          weight: 1
```

- [ ] **Step 2: Render-test**

Run: `make test-talos-ottawa`
Expected: exits 0; the rendered `HTTPRoute/trades-cdn` backend is `garage-web-cache` port `80` and its `Cache-Control` is `public, max-age=60, stale-while-revalidate=30`.

- [ ] **Step 3: Commit and push**

```bash
git add kubernetes/components/cdn-site/httproute.yaml
git commit -m "cdn-site: serve through garage-web-cache with short browser TTL"
git push
```

---

### Task 3: Route the keiretsu root site through the cache

**Files:**
- Modify: `kubernetes/apps/base/garage/garage/httproute-web.yaml:40-50` (Cache-Control value + backendRefs)

**Interfaces:**
- Consumes: Service `garage-web-cache:80` (Task 1).

- [ ] **Step 1: Point the backend at the cache and lower the browser TTL**

In `kubernetes/apps/base/garage/garage/httproute-web.yaml`, replace:

```yaml
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            add:
              - name: Cache-Control
                value: "public, max-age=3600"
      backendRefs:
        - group: ""
          kind: Service
          name: garage-gateway
          port: 3902
          weight: 1
```

with:

```yaml
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            add:
              - name: Cache-Control
                value: "public, max-age=60, stale-while-revalidate=30"
      backendRefs:
        - group: ""
          kind: Service
          name: garage-web-cache
          port: 80
          weight: 1
```

- [ ] **Step 2: Render-test all clusters**

Run: `make test`
Expected: exits 0 for all three clusters; the rendered `HTTPRoute/garage-web` backend is `garage-web-cache` port `80`.

- [ ] **Step 3: Commit and push**

```bash
git add kubernetes/apps/base/garage/garage/httproute-web.yaml
git commit -m "garage: serve keiretsu root site through garage-web-cache"
git push
```

---

### Task 4: Deploy and live-validate on Ottawa

**Files:** none (reconcile + observe).

Uses `KUBECONFIG=/workspace/kubernetes-manifests/.kube/config` and the Ottawa context (`ottawa-k8s-operator.keiretsu.ts.net`). Pod/service CIDRs are locally routable over Tailscale — you can `curl` cluster IPs directly.

- [ ] **Step 1: Reconcile and confirm the cache is running**

```bash
export KUBECONFIG=/workspace/kubernetes-manifests/.kube/config
flux reconcile kustomization garage -n flux-system --context ottawa-k8s-operator.keiretsu.ts.net
kubectl --context ottawa-k8s-operator.keiretsu.ts.net -n garage rollout status deploy/garage-web-cache
```
Expected: deployment becomes Available with 2/2 ready. If pods CrashLoop on a read-only-fs error, add a `/tmp` emptyDir mount (see Task 1 Step 2 note), re-render, commit, reconcile.

- [ ] **Step 2: Verify MISS → HIT and the cache-status header**

```bash
CIP=$(kubectl --context ottawa-k8s-operator.keiretsu.ts.net -n garage get svc garage-web-cache -o jsonpath='{.spec.clusterIP}')
# First request populates the cache, second should hit.
curl -s -o /dev/null -D - -H 'Host: raj-assistant-web.keiretsu.top' "http://$CIP/index.html" | grep -i x-cache-status
curl -s -o /dev/null -D - -H 'Host: raj-assistant-web.keiretsu.top' "http://$CIP/index.html" | grep -i x-cache-status
```
Expected: first `X-Cache-Status: MISS`, second `X-Cache-Status: HIT`.

- [ ] **Step 3: Verify conditional revalidation returns 304 (cheap origin check)**

```bash
GIP=$(kubectl --context ottawa-k8s-operator.keiretsu.ts.net -n garage get svc garage-gateway -o jsonpath='{.spec.clusterIP}')
ETAG=$(curl -s -D - -o /dev/null -H 'Host: raj-assistant-web.keiretsu.top' "http://$GIP:3902/index.html" | awk -F'"' 'tolower($0) ~ /etag/ {print $2}')
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: raj-assistant-web.keiretsu.top' -H "If-None-Match: \"$ETAG\"" "http://$GIP:3902/index.html"
```
Expected: `304`. (Confirms the `proxy_cache_revalidate` design is valid against Garage v2. If Garage returns `200` instead, revalidation still works but costs a full body — note it and consider dropping the edge TTL further or adding purge-on-deploy.)

- [ ] **Step 4: Verify end-to-end through the public gateway and browser TTL**

```bash
curl -s -D - -o /dev/null https://trades.rajsingh.info/ | grep -iE 'cache-control|x-cache-status'
```
Expected: `Cache-Control: public, max-age=60, stale-while-revalidate=30` and an `X-Cache-Status` header present.

- [ ] **Step 5: Confirm low, flat RAM**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net -n garage top pod -l app.kubernetes.io/name=garage-web-cache
```
Expected: memory in the tens of MB (well under the 64Mi limit), and it stays flat as more objects are cached — bodies are on disk, not RAM.

- [ ] **Step 6: Record the outcome**

No commit. Note pass/fail of each check in the branch's PR description or a short summary.

---

## Rollback

Each routing change (Tasks 2, 3) is an independent commit; revert the backendRef commit(s) to send traffic straight back to `garage-gateway:3902`. Task 1's cache is inert until a route points at it, so it can be left in place or reverted separately.
