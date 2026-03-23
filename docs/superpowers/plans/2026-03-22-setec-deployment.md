# Setec Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy setec secrets server to all clusters via Flux common apps, with Garage S3 for backup/restore and `--dev` mode encryption.

**Architecture:** Deployment (not StatefulSet) with emptyDir volume. Init container restores latest backup from Garage S3 on every pod start. Main container runs setec in `--dev` mode, backing up to Garage on every change. State is ephemeral — Garage is the durable layer. Failover is automatic: any cluster can start setec and reconstruct state from Garage.

**Tech Stack:** setec (Go, tsnet), Flux CD, Garage (S3-compatible), AWS CLI (init container), Kustomize

---

## File Structure

```
clusters/common/apps/setec/
├── kustomization.yaml          # Top-level: references namespace.yaml + ks.yaml
├── ks.yaml                     # Flux Kustomization pointing to ./app
├── namespace.yaml              # setec namespace
└── app/
    ├── kustomization.yaml      # App-level: sets namespace, lists resources
    ├── deployment.yaml         # Deployment with init container + setec container
    └── secret.yaml             # TS_AUTHKEY + S3 credentials (Flux-substituted)

clusters/common/apps/garage/bucket/
├── bucket.yaml                 # MODIFY: add setec GarageBucket
└── key.yaml                    # MODIFY: add setec GarageKey (secret into setec namespace)

clusters/common/apps/
└── kustomization.yaml          # MODIFY: add setec to resources list
```

---

### Task 1: Add Garage Bucket and Key for setec

**Files:**
- Modify: `clusters/common/apps/garage/bucket/bucket.yaml`
- Modify: `clusters/common/apps/garage/bucket/key.yaml`

- [ ] **Step 1: Add GarageBucket for setec**

Append to `clusters/common/apps/garage/bucket/bucket.yaml`:

```yaml
---
apiVersion: garage.rajsingh.info/v1alpha1
kind: GarageBucket
metadata:
  name: setec
spec:
  clusterRef:
    name: garage
  globalAlias: setec
  quotas:
    maxSize: 10Gi
    maxObjects: 100000
  keyPermissions:
    - keyRef: setec-key
      read: true
      write: true
```

- [ ] **Step 2: Add GarageKey for setec**

Append to `clusters/common/apps/garage/bucket/key.yaml`:

```yaml
---
apiVersion: garage.rajsingh.info/v1alpha1
kind: GarageKey
metadata:
  name: setec-key
spec:
  clusterRef:
    name: garage
  name: "Setec Backup Key"
  secretTemplate:
    name: setec-s3-auth
    namespace: setec
    accessKeyIdKey: AWS_ACCESS_KEY_ID
    secretAccessKeyKey: AWS_SECRET_ACCESS_KEY
  bucketPermissions:
    - bucketRef: setec
      read: true
      write: true
```

This creates a Secret `setec-s3-auth` in the `setec` namespace with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

- [ ] **Step 3: Commit**

```bash
git add clusters/common/apps/garage/bucket/bucket.yaml clusters/common/apps/garage/bucket/key.yaml
git commit -m "add Garage bucket and key for setec backups"
```

---

### Task 2: Create setec namespace and Flux Kustomization

**Files:**
- Create: `clusters/common/apps/setec/namespace.yaml`
- Create: `clusters/common/apps/setec/ks.yaml`
- Create: `clusters/common/apps/setec/kustomization.yaml`

- [ ] **Step 1: Create namespace.yaml**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: setec
  labels:
    kustomize.toolkit.fluxcd.io/prune: disabled
```

- [ ] **Step 2: Create ks.yaml**

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app setec
  namespace: flux-system
spec:
  targetNamespace: setec
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: garage-bucket
  path: ./clusters/common/apps/setec/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: kubernetes-manifests
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

- [ ] **Step 3: Create kustomization.yaml**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./ks.yaml
```

- [ ] **Step 4: Commit**

```bash
git add clusters/common/apps/setec/namespace.yaml clusters/common/apps/setec/ks.yaml clusters/common/apps/setec/kustomization.yaml
git commit -m "add setec namespace and Flux Kustomization"
```

---

### Task 3: Create setec app manifests

**Files:**
- Create: `clusters/common/apps/setec/app/deployment.yaml`
- Create: `clusters/common/apps/setec/app/secret.yaml`
- Create: `clusters/common/apps/setec/app/kustomization.yaml`

- [ ] **Step 1: Create secret.yaml**

This uses Flux variable substitution. `TS_AUTHKEY` comes from cluster-secrets, `COMMON_S3_ENDPOINT` from common-settings. The S3 credentials come from the Garage-created `setec-s3-auth` secret (Task 1), so we reference that directly in the Deployment envFrom — no need to duplicate here.

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: setec-tailscale
type: Opaque
stringData:
  TS_AUTHKEY: ${TS_OAUTH_CLIENT_SECRET}?ephemeral=false&preauthorized=true
```

- [ ] **Step 2: Create deployment.yaml**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: setec
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: setec
  template:
    metadata:
      labels:
        app: setec
    spec:
      initContainers:
        - name: restore-backup
          image: amazon/aws-cli:latest
          command:
            - sh
            - -c
            - |
              export AWS_ENDPOINT_URL_S3="http://${S3_ENDPOINT}"
              LATEST=$(aws s3 ls s3://setec/ --recursive 2>/dev/null | sort | tail -1 | awk '{print $4}')
              if [ -n "$LATEST" ]; then
                echo "Restoring backup: $LATEST"
                aws s3 cp "s3://setec/$LATEST" /app/state/database
                echo "Restore complete"
              else
                echo "No backup found, starting fresh"
              fi
          env:
            - name: S3_ENDPOINT
              value: "${COMMON_S3_ENDPOINT}"
          envFrom:
            - secretRef:
                name: setec-s3-auth
          volumeMounts:
            - name: state
              mountPath: /app/state
      containers:
        - name: setec
          image: ghcr.io/tailscale/setec:latest
          args:
            - server
            - --dev
            - --hostname
            - ${LOCATION}-secrets
            - --state-dir
            - /app/state
            - --backup-bucket
            - setec
            - --backup-bucket-region
            - garage
          env:
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: setec-tailscale
                  key: TS_AUTHKEY
            - name: AWS_ENDPOINT_URL_S3
              value: "http://${COMMON_S3_ENDPOINT}"
          envFrom:
            - secretRef:
                name: setec-s3-auth
          volumeMounts:
            - name: state
              mountPath: /app/state
      volumes:
        - name: state
          emptyDir: {}
```

**Key details:**
- Init container uses `aws s3 ls --recursive` to find the latest backup by sorted key path (`YYYY/M/D/db-*.json`)
- `AWS_ENDPOINT_URL_S3` env var makes the AWS SDK v2 use Garage instead of AWS S3 — no setec code changes needed
- `COMMON_S3_ENDPOINT` and `LOCATION` are Flux-substituted variables
- `setec-s3-auth` secret is created by the Garage operator (Task 1)
- `emptyDir` — no PVC needed, state reconstructed from S3 on every start

- [ ] **Step 3: Create app kustomization.yaml**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: setec
resources:
  - secret.yaml
  - deployment.yaml
```

- [ ] **Step 4: Commit**

```bash
git add clusters/common/apps/setec/app/
git commit -m "add setec deployment with Garage S3 backup/restore"
```

---

### Task 4: Register setec in common apps

**Files:**
- Modify: `clusters/common/apps/kustomization.yaml`

- [ ] **Step 1: Add setec to the common apps resource list**

Add `- ./setec` to the resources list in `clusters/common/apps/kustomization.yaml`, alphabetically with existing entries.

- [ ] **Step 2: Commit**

```bash
git add clusters/common/apps/kustomization.yaml
git commit -m "register setec in common apps"
```

---

### Task 5: Build and push setec container image

**Files:** None (external action)

The Dockerfile in `../setec` uses `ghcr.io/tailscale/setec:latest` as the implied upstream image tag. We need to verify this image exists or build/push our own.

- [ ] **Step 1: Check if upstream image exists**

```bash
docker pull ghcr.io/tailscale/setec:latest 2>/dev/null && echo "exists" || echo "need to build"
```

- [ ] **Step 2: If no upstream image, build and push**

```bash
cd /Users/rajsingh/Documents/GitHub/setec
docker build -t ghcr.io/rajsinghtech/setec:latest .
docker push ghcr.io/rajsinghtech/setec:latest
```

Then update `deployment.yaml` image to `ghcr.io/rajsinghtech/setec:latest`.

- [ ] **Step 3: Commit image reference change if needed**

```bash
git add clusters/common/apps/setec/app/deployment.yaml
git commit -m "use rajsinghtech setec image"
```

---

### Task 6: Verify deployment

- [ ] **Step 1: Push to Git and wait for Flux reconciliation**

```bash
git push
```

Or force reconcile:

```bash
flux reconcile kustomization common-apps -n flux-system --context kubernetes-robbinsdale.keiretsu.ts.net
```

- [ ] **Step 2: Check Garage bucket was created**

```bash
kubectl --context kubernetes-robbinsdale.keiretsu.ts.net get garagebucket setec -n garage
```

- [ ] **Step 3: Check setec pod is running**

```bash
kubectl --context kubernetes-robbinsdale.keiretsu.ts.net get pods -n setec
kubectl --context kubernetes-robbinsdale.keiretsu.ts.net logs -n setec deployment/setec -c restore-backup
kubectl --context kubernetes-robbinsdale.keiretsu.ts.net logs -n setec deployment/setec -c setec
```

Expected: init container logs "No backup found, starting fresh" on first run; setec container logs "dev mode" messages and "tailscale did come up".

- [ ] **Step 4: Verify setec is reachable on tailnet**

```bash
curl -s https://robbinsdale-secrets.keiretsu.ts.net/ 2>/dev/null | head -5
```

- [ ] **Step 5: Test a secret round-trip**

```bash
# Install CLI
go install github.com/tailscale/setec/cmd/setec@latest

# Put a test secret
echo -n "hello-world" | setec -s https://robbinsdale-secrets.keiretsu.ts.net put test/hello

# Get it back
setec -s https://robbinsdale-secrets.keiretsu.ts.net get test/hello
```

Expected: returns `hello-world`.

- [ ] **Step 6: Verify backup to Garage**

Wait ~1 minute after the put, then:

```bash
# Check backup exists in Garage
aws --endpoint-url http://<COMMON_S3_ENDPOINT> s3 ls s3://setec/ --recursive
```

Expected: a `YYYY/M/D/db-*.json` file appears.

- [ ] **Step 7: Test restore cycle**

```bash
# Delete the pod (forces restart + restore from S3)
kubectl --context kubernetes-robbinsdale.keiretsu.ts.net delete pod -n setec -l app=setec

# Wait for new pod
kubectl --context kubernetes-robbinsdale.keiretsu.ts.net wait --for=condition=ready pod -n setec -l app=setec --timeout=120s

# Verify secret survived
setec -s https://robbinsdale-secrets.keiretsu.ts.net get test/hello
```

Expected: returns `hello-world` — proves backup/restore cycle works.

---

## Future Work (not in this plan)

- **Tailscale ACL grant**: Add `tailscale.com/cap/secrets` grants to `tailscale/policy.hujson` for fine-grained access control
- **KMS migration**: Replace `--dev` dummy encryption with age-based KMS
- **Karmada failover**: Once verified on Robbinsdale, add PropagationPolicy for automatic failover to Ottawa/StPetersburg
- **Monitoring**: Add ServiceMonitor for setec expvar metrics
