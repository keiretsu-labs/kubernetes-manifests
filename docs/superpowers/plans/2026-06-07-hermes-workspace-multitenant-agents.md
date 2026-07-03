# hermes-workspace multi-tenant agents — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable "group-served Hermes" app shape to the `agents` namespace whose front door is the public `*.agents.${COMMON_DOMAIN}` Envoy Gateway with Pocket ID OIDC, so each tenant group (single-person or multi-user) is one `kustomize build`-clean overlay.

**Architecture:** A shared Kustomize **Component** (`_component/hermes-group`) carries the full per-group manifest set (hermes gateway + workspace sidecar pod, Service, HTTPRoute, OIDC SecurityPolicy, StorageStack, GarageKey, ConfigMap). Each group is a tiny overlay under `app/groups/<group>/` that supplies values through a `group-meta` ConfigMap consumed by Kustomize `replacements`. One new wildcard listener + cert on the existing public Gateway terminates `*.agents.${COMMON_DOMAIN}`.

**Tech Stack:** Flux + Kustomize (components/replacements), Envoy Gateway (Gateway API + `SecurityPolicy.oidc`), Pocket ID, cert-manager, SOPS, Garage operator, StorageStack operator, `nousresearch/hermes-agent` + `ghcr.io/outsourc-e/hermes-workspace`.

> **Decision to confirm before execution (resolves spec O2):** this plan injects per-group values with Kustomize `replacements`. It works but is verbose. The same Component can instead be driven by Flux `${GROUP}` substitution + a per-group `ks.yaml` (fewer lines, repo-native). If you'd prefer that mechanism, say so and Tasks 2–3 swap; everything else is identical.

**Spec:** `docs/superpowers/specs/2026-06-07-hermes-workspace-multitenant-agents-design.md`

**Conventions used below:** all work happens on branch `feat/hermes-workspace-multitenant` in `keiretsu-labs/kubernetes-manifests`. `CLUSTER_NAME` is `talos-ottawa`. Render checks use `kustomize build --enable-helm` only where needed (not here). Commits follow the repo style (no Claude attribution).

---

## File Structure

**Shared / one-time (Task 1):**
- Create `clusters/common/apps/home/local-gateway/certificate-agents.yaml` — wildcard cert for `*.agents.${COMMON_DOMAIN}`.
- Modify `clusters/common/apps/home/local-gateway/kustomization.yaml` — add the cert.
- Modify `clusters/common/apps/home/local-gateway/gateway-public.yaml` — add the `*.agents` HTTPS listener.

**Component (Task 2):** `clusters/talos-ottawa/apps/agents/app/_component/hermes-group/`
- `kustomization.yaml` (`kind: Component`, resources + replacements)
- `deployment.yaml`, `service.yaml`, `httproute.yaml`, `securitypolicy.yaml`, `storagestack.yaml`, `garagekey.yaml`, `configmap.yaml`

**Per-group overlay (Task 3–4):** `clusters/talos-ottawa/apps/agents/app/groups/<group>/`
- `kustomization.yaml` (component ref + `group-meta` + persona patch)
- `secret.sops.yaml` (`API_SERVER_KEY`, Pocket ID `client-secret`)
- Modify `clusters/talos-ottawa/apps/agents/app/kustomization.yaml` — add `- groups/<group>`.

---

## Task 1: Public `*.agents` wildcard listener + cert

**Files:**
- Create: `clusters/common/apps/home/local-gateway/certificate-agents.yaml`
- Modify: `clusters/common/apps/home/local-gateway/kustomization.yaml`
- Modify: `clusters/common/apps/home/local-gateway/gateway-public.yaml`

- [ ] **Step 1: Create the wildcard certificate**

`clusters/common/apps/home/local-gateway/certificate-agents.yaml`:
```yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-agents-${COMMON_DOMAIN//./-}
spec:
  dnsNames:
    - '*.agents.${COMMON_DOMAIN}'
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: keiretsu-top
  secretName: wildcard-agents-${COMMON_DOMAIN//./-}
  usages:
    - digital signature
    - key encipherment
```

- [ ] **Step 2: Register the cert in the local-gateway kustomization**

In `clusters/common/apps/home/local-gateway/kustomization.yaml`, append to `resources:`:
```yaml
  - certificate-agents.yaml
```

- [ ] **Step 3: Add the `*.agents` HTTPS listener to the public Gateway**

In `clusters/common/apps/home/local-gateway/gateway-public.yaml`, add this listener to `spec.listeners` (place it immediately after the `wildcard-${COMMON_DOMAIN//./-}-https` listener):
```yaml
    - name: wildcard-agents-${COMMON_DOMAIN//./-}-https
      protocol: HTTPS
      port: 443
      hostname: "*.agents.${COMMON_DOMAIN}"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
        - group: ''
          kind: Secret
          name: wildcard-agents-${COMMON_DOMAIN//./-}
```

- [ ] **Step 4: Render to verify it builds**

Run: `kustomize build clusters/common/apps/home/local-gateway`
Expected: succeeds; output contains a `Certificate` named `wildcard-agents-${COMMON_DOMAIN//./-}` and a Gateway listener `wildcard-agents-${COMMON_DOMAIN//./-}-https` with hostname `*.agents.${COMMON_DOMAIN}`.

- [ ] **Step 5: Commit**

```bash
git add clusters/common/apps/home/local-gateway/certificate-agents.yaml \
        clusters/common/apps/home/local-gateway/kustomization.yaml \
        clusters/common/apps/home/local-gateway/gateway-public.yaml
git commit -m "feat(gateway): add *.agents wildcard listener and cert"
```

---

## Task 2: hermes-group Kustomize Component

Creates the reusable shape. Base names use the literal token `placeholder`; Task 2's replacements rewrite it from the overlay's `group-meta` ConfigMap. The `${COMMON_DOMAIN}` token is left intact for Flux to substitute at apply time.

**Files (all Create):** under `clusters/talos-ottawa/apps/agents/app/_component/hermes-group/`

- [ ] **Step 1: Deployment (gateway + workspace sidecar)**

`deployment.yaml`:
```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-placeholder
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: hermes-placeholder
  template:
    metadata:
      labels:
        app.kubernetes.io/name: hermes-placeholder
    spec:
      containers:
        - name: gateway
          image: nousresearch/hermes-agent:v2026.6.5
          args: ["gateway", "run"]
          envFrom:
            - configMapRef:
                name: hermes-placeholder-config
            - secretRef:
                name: hermes-placeholder-secrets
          env:
            - name: HERMES_DASHBOARD
              value: "1"
            - name: HERMES_DASHBOARD_HOST
              value: "127.0.0.1"
            - name: HERMES_DASHBOARD_PORT
              value: "9119"
            - name: HERMES_DASHBOARD_INSECURE
              value: "1"
          ports:
            - name: gateway
              containerPort: 8642
            - name: dashboard
              containerPort: 9119
          resources:
            requests:
              cpu: 1000m
              memory: 2Gi
            limits:
              memory: 6Gi
          volumeMounts:
            - name: data
              mountPath: /opt/data
            - name: shm
              mountPath: /dev/shm
        - name: workspace
          image: ghcr.io/outsourc-e/hermes-workspace:v0.4.0
          env:
            - name: HERMES_API_URL
              value: "http://127.0.0.1:8642"
            - name: HERMES_DASHBOARD_URL
              value: "http://127.0.0.1:9119"
            - name: HERMES_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hermes-placeholder-secrets
                  key: API_SERVER_KEY
            - name: HERMES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: hermes-placeholder-secrets
                  key: API_SERVER_KEY
            - name: PORT
              value: "3000"
          ports:
            - name: workspace
              containerPort: 3000
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: hermes-placeholder-data
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
      terminationGracePeriodSeconds: 30
```

> **O5 note:** image tags `nousresearch/hermes-agent:v2026.6.5` and `ghcr.io/outsourc-e/hermes-workspace:v0.4.0` are the assumed pins. Before committing, confirm the latest matching tags (`docker buildx imagetools inspect ghcr.io/outsourc-e/hermes-workspace:latest` for the digest/tag, and that the workspace's expected gateway API matches the hermes-agent tag). Update both if needed.

- [ ] **Step 2: Service (ClusterIP)**

`service.yaml`:
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-placeholder
spec:
  selector:
    app.kubernetes.io/name: hermes-placeholder
  ports:
    - name: workspace
      port: 3000
      targetPort: 3000
    - name: gateway
      port: 8642
      targetPort: 8642
```

- [ ] **Step 3: HTTPRoute (public subdomain → workspace :3000)**

`httproute.yaml`:
```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hermes-placeholder
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: public
      namespace: home
  hostnames:
    - "placeholder.agents.${COMMON_DOMAIN}"
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: hermes-placeholder
          port: 3000
          weight: 1
      matches:
        - path:
            type: PathPrefix
            value: /
```

- [ ] **Step 4: SecurityPolicy (OIDC via per-group Pocket ID client)**

`securitypolicy.yaml`:
```yaml
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: hermes-placeholder
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: hermes-placeholder
  oidc:
    provider:
      issuer: "https://pocket-id.${COMMON_DOMAIN}"
    clientID: "placeholder-client-id"
    clientSecret:
      name: hermes-placeholder-oidc
    redirectURL: "https://placeholder/oauth2/callback"
    logoutPath: "/logout"
    cookieDomain: "agents.${COMMON_DOMAIN}"
```

- [ ] **Step 5: StorageStack (PVC + nightly Garage backup)**

`storagestack.yaml`:
```yaml
---
apiVersion: storage.keiretsu.ts.net/v1alpha1
kind: StorageStack
metadata:
  name: hermes-placeholder-data
  labels:
    keiretsu.ts.net/location: ottawa
spec:
  name: hermes-placeholder-data
  size: 20Gi
  storageClass: ceph-block-replicated
  s3Path: agents/placeholder
  schedule: 0 4 * * *
  copyMethod: Snapshot
```

- [ ] **Step 6: GarageKey (per-group S3 creds, owns its path)**

`garagekey.yaml`:
```yaml
---
apiVersion: garage.rajsingh.info/v1beta1
kind: GarageKey
metadata:
  name: hermes-placeholder-s3-key
spec:
  clusterRef:
    name: garage
    namespace: garage
  name: "hermes-placeholder"
  secretTemplate:
    name: hermes-placeholder-s3
    accessKeyIdKey: AWS_ACCESS_KEY_ID
    secretAccessKeyKey: AWS_SECRET_ACCESS_KEY
  bucketPermissions:
    - bucketRef:
        name: agents
        namespace: garage
      read: true
      write: true
```

- [ ] **Step 7: ConfigMap (Hermes + LLM env, persona placeholder)**

`configmap.yaml`:
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-placeholder-config
data:
  GATEWAY_ALLOW_ALL_USERS: "true"
  API_SERVER_ENABLED: "true"
  API_SERVER_HOST: "0.0.0.0"
  API_SERVER_PORT: "8642"
  API_SERVER_KEY: "${DEFAULT_PASSWORD}"
  OPENAI_BASE_URL: "http://stpetersburg-vllm/v1"
  OPENAI_API_KEY: "unused"
  AGENT_NAME: "placeholder"
  AGENT_SYSTEM_PROMPT: |
    You are a group assistant. Override this per group.
```

> Note: `API_SERVER_KEY` here mirrors the existing agents' Flux `${DEFAULT_PASSWORD}` convention for the gateway bind; the workspace sidecar reads the real per-group key from the `hermes-placeholder-secrets` Secret (Task 4). If you want a distinct per-group gateway key, drop this line and set `API_SERVER_KEY` in the SOPS secret instead — keep ConfigMap and Secret consistent.

- [ ] **Step 8: Component kustomization with replacements**

`kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - configmap.yaml
  - deployment.yaml
  - service.yaml
  - httproute.yaml
  - securitypolicy.yaml
  - storagestack.yaml
  - garagekey.yaml
replacements:
  # group name -> every "hermes-placeholder*" metadata.name and label/selector
  - source:
      kind: ConfigMap
      name: group-meta
      fieldPath: data.name
    targets:
      - select: { kind: Deployment, name: hermes-placeholder }
        fieldPaths:
          - metadata.name
          - spec.selector.matchLabels.[app.kubernetes.io/name]
          - spec.template.metadata.labels.[app.kubernetes.io/name]
          - spec.template.spec.volumes.0.persistentVolumeClaim.claimName
          - spec.template.spec.containers.0.envFrom.0.configMapRef.name
          - spec.template.spec.containers.0.envFrom.1.secretRef.name
          - spec.template.spec.containers.1.env.2.valueFrom.secretKeyRef.name
          - spec.template.spec.containers.1.env.3.valueFrom.secretKeyRef.name
        options: { delimiter: "-", index: 1 }
      - select: { kind: Service, name: hermes-placeholder }
        fieldPaths:
          - metadata.name
          - spec.selector.[app.kubernetes.io/name]
        options: { delimiter: "-", index: 1 }
      - select: { kind: HTTPRoute, name: hermes-placeholder }
        fieldPaths:
          - metadata.name
          - spec.rules.0.backendRefs.0.name
        options: { delimiter: "-", index: 1 }
      - select: { group: gateway.envoyproxy.io, kind: SecurityPolicy, name: hermes-placeholder }
        fieldPaths:
          - metadata.name
          - spec.targetRefs.0.name
          - spec.oidc.clientSecret.name
        options: { delimiter: "-", index: 1 }
      - select: { kind: StorageStack, name: hermes-placeholder-data }
        fieldPaths:
          - metadata.name
          - spec.name
        options: { delimiter: "-", index: 1 }
      - select: { group: garage.rajsingh.info, kind: GarageKey }
        fieldPaths:
          - metadata.name
          - spec.name
          - spec.secretTemplate.name
        options: { delimiter: "-", index: 1 }
      - select: { kind: ConfigMap, name: hermes-placeholder-config }
        fieldPaths:
          - metadata.name
          - data.AGENT_NAME
        options: { delimiter: "-", index: 1 }
  # s3Path agents/placeholder -> agents/<name>
  - source: { kind: ConfigMap, name: group-meta, fieldPath: data.name }
    targets:
      - select: { kind: StorageStack }
        fieldPaths: [ spec.s3Path ]
        options: { delimiter: "/", index: 1 }
  # full host -> HTTPRoute hostname and SecurityPolicy redirectURL path
  - source: { kind: ConfigMap, name: group-meta, fieldPath: data.host }
    targets:
      - select: { kind: HTTPRoute }
        fieldPaths: [ spec.hostnames.0 ]
      - select: { group: gateway.envoyproxy.io, kind: SecurityPolicy }
        fieldPaths: [ spec.oidc.redirectURL ]
        options: { delimiter: "/", index: 2 }
  # pocket id client id
  - source: { kind: ConfigMap, name: group-meta, fieldPath: data.clientID }
    targets:
      - select: { group: gateway.envoyproxy.io, kind: SecurityPolicy }
        fieldPaths: [ spec.oidc.clientID ]
  # pvc size
  - source: { kind: ConfigMap, name: group-meta, fieldPath: data.size }
    targets:
      - select: { kind: StorageStack }
        fieldPaths: [ spec.size ]
```

> **Why these `delimiter`/`index` values:** base names are `hermes-placeholder` → split on `-` keeps `hermes` at index 0 and rewrites `placeholder` at index 1. `s3Path` `agents/placeholder` splits on `/` (index 1). `redirectURL` `https://placeholder/oauth2/callback` splits on `/` → index 2 is `placeholder`, replaced with the full host. Verify the container/env array indices in `deployment.yaml` match if you reorder that file.

- [ ] **Step 9: Commit the component**

```bash
git add clusters/talos-ottawa/apps/agents/app/_component/hermes-group
git commit -m "feat(agents): add hermes-group kustomize component"
```

---

## Task 3: First group overlay (`demo`) + render-gate

Proves the component renders with a real group. `demo` is a throwaway tenant; keep or delete after validation.

**Files:**
- Create: `clusters/talos-ottawa/apps/agents/app/groups/demo/kustomization.yaml`
- Create: `clusters/talos-ottawa/apps/agents/app/groups/demo/secret.sops.yaml` (Task 4 encrypts it)
- Modify: `clusters/talos-ottawa/apps/agents/app/kustomization.yaml`

- [ ] **Step 1: Overlay kustomization**

`groups/demo/kustomization.yaml`:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: agents
components:
  - ../../_component/hermes-group
generatorOptions:
  disableNameSuffixHash: true
configMapGenerator:
  - name: group-meta
    literals:
      - name=demo
      - host=demo.agents.${COMMON_DOMAIN}
      - clientID=REPLACE_WITH_POCKET_ID_CLIENT_ID
      - size=20Gi
resources:
  - secret.sops.yaml
patches:
  - target:
      kind: ConfigMap
      name: hermes-placeholder-config
    patch: |-
      - op: replace
        path: /data/AGENT_SYSTEM_PROMPT
        value: |
          You are the Demo group's shared assistant.
          Keep answers terse and technical.
```

- [ ] **Step 2: Plaintext secret (pre-encryption)**

`groups/demo/secret.sops.yaml` (plaintext for now; Task 4 encrypts in place):
```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: hermes-demo-secrets
type: Opaque
stringData:
  API_SERVER_KEY: "CHANGEME-demo-gateway-bearer"
---
apiVersion: v1
kind: Secret
metadata:
  name: hermes-demo-oidc
type: Opaque
stringData:
  client-secret: "CHANGEME-pocket-id-client-secret"
```

> Secret names are the post-replacement names (`hermes-demo-secrets`, `hermes-demo-oidc`) because the SOPS secret is a plain `resources` entry, not run through the component's replacements. Keep them in sync with `name=demo`.

- [ ] **Step 3: Wire the overlay into the agents app**

In `clusters/talos-ottawa/apps/agents/app/kustomization.yaml`, append to `resources:`:
```yaml
  - groups/demo
```

- [ ] **Step 4: Render the whole agents app**

Run: `kustomize build clusters/talos-ottawa/apps/agents/app`
Expected: succeeds. In the output confirm for `demo`:
- `Deployment/hermes-demo` with two containers (`gateway`, `workspace`) and `claimName: hermes-demo-data`
- `Service/hermes-demo` selector `app.kubernetes.io/name: hermes-demo`
- `HTTPRoute/hermes-demo` hostname `demo.agents.${COMMON_DOMAIN}`, backendRef `hermes-demo`
- `SecurityPolicy/hermes-demo` `redirectURL: https://demo.agents.${COMMON_DOMAIN}/oauth2/callback`, `clientSecret.name: hermes-demo-oidc`
- `StorageStack/hermes-demo-data` `s3Path: agents/demo`
- `GarageKey/hermes-demo-s3-key`
- the existing 5 agents still render unchanged

- [ ] **Step 5: Schema-validate the render**

Run: `kustomize build clusters/talos-ottawa/apps/agents/app | kubeconform -strict -ignore-missing-schemas -summary`
Expected: `0 errors`. (CRDs like StorageStack/GarageKey/SecurityPolicy are skipped by `-ignore-missing-schemas`; core kinds must pass.)

- [ ] **Step 6: Commit (secret still plaintext — do NOT push yet)**

```bash
git add clusters/talos-ottawa/apps/agents/app/groups/demo/kustomization.yaml \
        clusters/talos-ottawa/apps/agents/app/kustomization.yaml
git commit -m "feat(agents): add demo group overlay"
```

---

## Task 4: Pocket ID client + encrypt the secret

**Files:**
- Modify (out-of-band): Pocket ID admin UI
- Modify: `clusters/talos-ottawa/apps/agents/app/groups/demo/kustomization.yaml` (real clientID)
- Encrypt: `clusters/talos-ottawa/apps/agents/app/groups/demo/secret.sops.yaml`

- [ ] **Step 1: Create the Pocket ID OAuth client**

In Pocket ID (`https://pocket-id.${COMMON_DOMAIN}`): create an OAuth2 client `hermes-demo`.
- Redirect URI: `https://demo.agents.${COMMON_DOMAIN}/oauth2/callback`
- Allowed user-group: the group that should reach `demo` (create it; add members). For a single-person group, a group with one member.
- Capture the generated **client ID** and **client secret**.

- [ ] **Step 2: Put the real client ID in the overlay**

In `groups/demo/kustomization.yaml`, replace `REPLACE_WITH_POCKET_ID_CLIENT_ID` with the captured client ID.

- [ ] **Step 3: Put real secret values in the plaintext secret**

Edit `groups/demo/secret.sops.yaml`: set `API_SERVER_KEY` to a freshly generated token (`openssl rand -hex 24`) and `client-secret` to the Pocket ID client secret.

- [ ] **Step 4: Encrypt in place with SOPS**

Run: `sops --encrypt --in-place clusters/talos-ottawa/apps/agents/app/groups/demo/secret.sops.yaml`
Expected: the file's `stringData` values are replaced with `ENC[...]` blocks and a `sops:` metadata block is appended. (Uses the repo `.sops.yaml` rules + `sops-gpg`, the same key `agents/ks.yaml` decrypts with.)

- [ ] **Step 5: Re-render to confirm SOPS file still parses as a Secret**

Run: `kustomize build clusters/talos-ottawa/apps/agents/app | grep -A2 'kind: Secret' | grep hermes-demo`
Expected: both `hermes-demo-secrets` and `hermes-demo-oidc` appear (kustomize treats the encrypted file as a normal manifest; Flux decrypts at apply).

- [ ] **Step 6: Commit**

```bash
git add clusters/talos-ottawa/apps/agents/app/groups/demo/kustomization.yaml \
        clusters/talos-ottawa/apps/agents/app/groups/demo/secret.sops.yaml
git commit -m "feat(agents): demo group oidc client id + encrypted secrets"
```

---

## Task 5: Flux dry-run, rollout, smoke test

- [ ] **Step 1: Flux client-side build of the agents Kustomization**

Run:
```bash
flux build kustomization agents \
  --path clusters/talos-ottawa/apps/agents/app \
  --kustomization-file clusters/talos-ottawa/apps/agents/ks.yaml \
  --dry-run
```
Expected: renders without error and shows `hermes-demo` resources with `${COMMON_DOMAIN}` / `${DEFAULT_PASSWORD}` substituted from local vars (or left as tokens in pure dry-run — acceptable; the goal is no template/build error).

- [ ] **Step 2: Push the branch and open a PR**

```bash
git push -u origin feat/hermes-workspace-multitenant
gh pr create --fill --base main
```

- [ ] **Step 3: After Flux reconciles, verify the rollout**

```bash
kubectl -n agents rollout status deploy/hermes-demo
kubectl -n agents get httproute hermes-demo securitypolicy hermes-demo
kubectl -n flux-system logs deploy/kustomize-controller | grep -i agents | tail
```
Expected: deployment Available; HTTPRoute `Accepted=True`; SecurityPolicy accepted.

- [ ] **Step 4: Smoke-test the front door**

- Browse to `https://demo.agents.${COMMON_DOMAIN}` as a **member** → redirected to Pocket ID → after login, the hermes-workspace UI loads and can chat (gateway reachable over loopback).
- Browse as a **non-member** → Pocket ID refuses to issue a token (access denied). This is the multi-tenant authz proof.
- Confirm `:8642` / `:9119` are NOT reachable publicly (only `:3000` via the route).

- [ ] **Step 5: Decide demo's fate**

Keep `demo` as a canary, or delete the overlay (`git rm -r groups/demo`, drop the `- groups/demo` line) and commit. Real groups are added by repeating Tasks 3–4 with a new `<group>`.

---

## "Add a group" quick reference (post-implementation)

1. Pocket ID: new client `hermes-<group>`, redirect `https://<group>.agents.${COMMON_DOMAIN}/oauth2/callback`, allowed user-group set.
2. `mkdir groups/<group>`; copy `groups/demo/kustomization.yaml` + `secret.sops.yaml`; set `name=<group>`, `host`, `clientID`, prompt, `size`; rotate `API_SERVER_KEY`; `sops --encrypt --in-place secret.sops.yaml`.
3. Add `- groups/<group>` to `app/kustomization.yaml`.
4. `kustomize build … | kubeconform` → commit → Flux.

---

## Self-Review

**Spec coverage:**
- Public `*.agents` OIDC entry → Task 1 (listener/cert) + component HTTPRoute/SecurityPolicy (Task 2) ✓
- Per-group Pocket ID client + allowed-group authz → Task 4 ✓
- Gateway + workspace sidecar pod → Task 2 Step 1 ✓
- Instance-per-group isolation (PVC/S3/key) → Task 2 Steps 5–6 ✓
- Kustomize component + tiny overlay → Tasks 2–3 ✓
- Tailscale egress unchanged → component ConfigMap points at `stpetersburg-vllm` ExternalName (already in namespace) ✓
- Always-on (no scale-to-zero) → `replicas: 1`, no KEDA ✓ (phase 2 noted in spec)
- O3 (per-group Garage key) → resolved via `GarageKey.bucketPermissions` (Task 2 Step 6), no shared `bucket.yaml` edits ✓
- O1/O4/O5 (cert issuer, image pins, version compat) → called out inline as confirm-before-commit notes ✓

**Placeholder scan:** the literal token `placeholder` is intentional (rewritten by replacements); `REPLACE_WITH_POCKET_ID_CLIENT_ID` / `CHANGEME-*` are filled in Task 4 with explicit steps. No unguided "add error handling"-style gaps.

**Name consistency:** base `hermes-placeholder*` → `hermes-<group>*` everywhere; secret names (`hermes-demo-secrets`, `hermes-demo-oidc`) match the Deployment's `secretRef`/`secretKeyRef` and SecurityPolicy `clientSecret.name`; `group-meta` keys (`name/host/clientID/size`) match every replacement source.
