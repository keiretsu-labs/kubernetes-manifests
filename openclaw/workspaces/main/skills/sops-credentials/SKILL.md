---
name: SOPS Credentials
description: >
  Reference for how secrets flow from SOPS-encrypted files in Git through Flux
  postBuild substitution into Kubernetes Secrets and Pods.

  Use when: Debugging why a pod can't read a credential, tracing where a
  secret value comes from, adding a new secret to the pipeline, or
  understanding the substitution chain (Git → Flux → Secret → Pod).

  Don't use when: The pod is crashing for non-credential reasons (use
  pod-troubleshooting). Don't use for Flux reconciliation failures (use
  flux-debugging). Don't use for OpenClaw-specific config escaping (use
  config-audit — that covers the $${VAR} pattern). Don't use for CI/CD
  pipeline issues (use ci-diagnosis).

  Outputs: Architecture reference. No artifacts — provides context for
  debugging credential issues across the kubernetes-manifests repo.
requires: [kubectl, flux]
---

# SOPS Credentials

## Routing

### Use This Skill When
- A pod can't authenticate to an external service and you need to trace the secret
- Adding a new secret to an application in kubernetes-manifests
- Understanding where `${VARIABLE_NAME}` in a manifest gets its value
- Debugging "secret not found" or empty credential errors
- Checking which secrets are cross-cluster vs per-cluster
- Someone asks "how do secrets work in this setup?"

### Don't Use This Skill When
- Pod is crashing for non-credential reasons → use **pod-troubleshooting**
- Flux reconciliation is failing → use **flux-debugging** (it covers SOPS decrypt errors)
- OpenClaw config needs `$${VAR}` escaping → use **config-audit**
- CI pipeline broke → use **ci-diagnosis**
- You need to encrypt a new secret with SOPS → that's a manual `sops` CLI operation on the host

## Architecture: The Secret Pipeline

```
┌──────────────────────────────────────────────────────────────┐
│                          Git Repo                            │
│  (keiretsu-labs/kubernetes-manifests)                         │
│                                                              │
│  common-secrets.sops.yaml ─────┐                             │
│  cluster-secrets.sops.yaml ────┤  SOPS-encrypted             │
│  common-settings.yaml ─────────┤  (+ plaintext ConfigMaps)   │
│  cluster-settings.yaml ────────┘                             │
└──────────────────┬───────────────────────────────────────────┘
                   │ Flux GitRepository source
                   ▼
┌──────────────────────────────────────────────────────────────┐
│               Flux Kustomize Controller                      │
│                                                              │
│  1. Decrypts SOPS files using sops-gpg Secret                │
│  2. Creates K8s Secrets in flux-system namespace             │
│  3. Runs postBuild substitution on all child Kustomizations  │
│     → replaces ${VAR_NAME} with decrypted values             │
│  4. Applies rendered manifests to the cluster                │
└──────────────────┬───────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────────────┐
│               Rendered Kubernetes Resources                  │
│                                                              │
│  Secret (with substituted values) ──→ Pod env / volume mount │
│  HelmRelease (with substituted values in .spec.values)       │
│  ConfigMap (with substituted values)                         │
└──────────────────────────────────────────────────────────────┘
```

## Secret Source Files

### Cross-Cluster Secrets (shared by all clusters)
```
clusters/common/flux/vars/common-secrets.sops.yaml
```
Contains: `DEFAULT_PASSWORD`, `CODER_OIDC_*`, `CLOUDFLARE_*`, `TAILSCALE_*`, `GARAGE_*`,
`HF_TOKEN`, `KUBERNETES_MANIFESTS_GITHUB_TOKEN`, `OCI_*`, `COMMON_RESTIC_SECRET`,
`COMMONTLSCRT`, `COMMONTLSKEY`, etc.

### Per-Cluster Secrets (unique to each cluster)
```
clusters/talos-ottawa/flux/vars/cluster-secrets.sops.yaml
clusters/talos-robbinsdale/flux/vars/cluster-secrets.sops.yaml
clusters/talos-stpetersburg/flux/vars/cluster-secrets.sops.yaml
clusters/gke-uscentral1/flux/vars/cluster-secrets.sops.yaml
```
Contains: `QB_WIREGUARD_*`, `SMB_*`, `PLEX_TOKEN`, `*_API_KEY` (per-cluster app keys),
`DISCORD_WEBHOOK_URL`, `TS_IDP_*`, `ARGOCD_OIDC_*`, etc.

### Plaintext Settings (non-secret config values)
```
clusters/common/flux/vars/common-settings.yaml          → COMMON_DOMAIN
clusters/talos-*/flux/vars/cluster-settings.yaml         → LOCATION, CLUSTER_DOMAIN,
                                                            LAN_GATEWAY_IP, CLUSTER_NAME, etc.
```

## PGP Key

All SOPS files are encrypted with a single PGP key:
```
Fingerprint: FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5
```
The private key is stored in the `sops-gpg` Secret in each cluster's `flux-system` namespace.

## Flux Substitution Configuration

The parent Kustomization (e.g., `clusters/common/flux/apps.yaml`) configures substitution:

```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-gpg          # PGP private key for decryption
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: common-settings  # COMMON_DOMAIN, etc.
      - kind: Secret
        name: common-secrets   # Decrypted from common-secrets.sops.yaml
      - kind: ConfigMap
        name: cluster-settings # LOCATION, CLUSTER_DOMAIN, LAN_GATEWAY_IP, etc.
      - kind: Secret
        name: cluster-secrets  # Decrypted from cluster-secrets.sops.yaml
      - kind: ConfigMap
        name: cluster-user-settings
        optional: true
      - kind: Secret
        name: cluster-user-secrets
        optional: true
```

A **patch** propagates this same `postBuild` config to all child Kustomizations
(unless they have label `substitution.flux.home.arpa/disabled: "true"`).

## Credential Delivery Patterns

### Pattern 1: Inline Config Substitution
**Used by:** unpoller, CDN routes, any HelmRelease with `${VAR}` in values

Flux substitutes `${VAR}` directly into the HelmRelease `.spec.values`. The value
becomes part of a config file or inline string rendered by Helm.

**Example — unpoller** (`clusters/common/apps/unpoller/app/helmrelease.yaml`):
```yaml
# In HelmRelease .spec.values.upConfig (a config file template):
[[unifi.controller]]
    url  = "https://${LAN_GATEWAY_IP}"
    user = "unpoller"
    pass = "Keiretsu${DEFAULT_PASSWORD}0"
```
- `${LAN_GATEWAY_IP}` comes from **cluster-settings** ConfigMap (per-cluster)
- `${DEFAULT_PASSWORD}` comes from **common-secrets** SOPS Secret (cross-cluster)
- Flux replaces both before Helm renders → the pod sees the final plaintext config

### Pattern 2: Substituted Secret → secretKeyRef
**Used by:** cloudflare DDNS, external-dns, any app needing a K8s Secret

A Secret manifest uses `${VAR}` placeholders in `stringData`. Flux substitutes
the values, creating a real K8s Secret. Pods reference it via `secretKeyRef`.

**Example — cloudflare** (`clusters/common/apps/cloudflare/app/secret.yaml`):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare
type: Opaque
stringData:
  KILLINIT_CC_CLOUDFLARE_API_TOKEN: ${KILLINIT_CC_CLOUDFLARE_API_TOKEN}
  RAJSINGH_INFO_CLOUDFLARE_API_TOKEN: ${RAJSINGH_INFO_CLOUDFLARE_API_TOKEN}
```

Then in the Deployment:
```yaml
env:
  - name: CLOUDFLARE_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare
        key: KILLINIT_CC_CLOUDFLARE_API_TOKEN
```

**Why use this pattern?** When you need a K8s Secret object that multiple pods
or Helm charts can reference independently. Also when you want to rename the
env var (the key in stringData differs from the env name).

### Pattern 3: Direct secretKeyRef from Existing Secrets
**Used by:** coder (DB URL from CNPG-generated secret), apps with operator-managed secrets

The pod references a Secret that was created by another controller (e.g., CloudNativePG
creates `coder-db-url`). No SOPS substitution is involved — the Secret already exists.

**Example — coder** (`clusters/common/apps/coder/app/helmrelease.yaml`):
```yaml
env:
  - name: CODER_PG_CONNECTION_URL
    valueFrom:
      secretKeyRef:
        name: coder-db-url    # Created by CNPG operator
        key: url
  - name: CODER_OIDC_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: coder-oidc      # Created from a plain secret.yaml in the app dir
        key: client-id
```

### Pattern 4: Domain/URL Substitution in HelmRelease
**Used by:** Nearly every app with an HTTPRoute or access URL

Non-secret config values (like domain names) are substituted from ConfigMaps.

**Example — coder**:
```yaml
- name: CODER_ACCESS_URL
  value: "https://coder.${CLUSTER_DOMAIN}"
```
- `${CLUSTER_DOMAIN}` comes from **cluster-settings** ConfigMap → `rajsingh.info`

## Debugging Credential Issues

### Tracing a Variable
To find where `${SOME_VAR}` gets its value:

```bash
# 1. Check if it's in common-secrets (cross-cluster)
#    Look for the key name in the SOPS file (keys are visible, values encrypted)
grep "SOME_VAR" clusters/common/flux/vars/common-secrets.sops.yaml

# 2. Check if it's in cluster-secrets (per-cluster)
grep "SOME_VAR" clusters/talos-*/flux/vars/cluster-secrets.sops.yaml

# 3. Check if it's in a plaintext ConfigMap
grep "SOME_VAR" clusters/common/flux/vars/common-settings.yaml
grep "SOME_VAR" clusters/talos-*/flux/vars/cluster-settings.yaml
```

### Verifying in the Cluster
```bash
# Check the decrypted secret in flux-system
kubectl get secret common-secrets -n flux-system -o jsonpath='{.data.DEFAULT_PASSWORD}' | base64 -d

# Check the rendered (substituted) secret in the app namespace
kubectl get secret cloudflare -n cloudflare -o yaml

# Check a pod's env vars
kubectl exec -n <namespace> <pod> -- env | grep <VAR>

# Verify Flux substitution happened
flux get kustomization common-apps -o yaml | grep -A20 postBuild
```

### Common Failures

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `${VAR_NAME}` appears literally in rendered manifest | Variable not in any `substituteFrom` source | Add it to the correct SOPS/ConfigMap file |
| Secret exists but value is empty | Key name mismatch between SOPS file and `${VAR}` | Check exact spelling in SOPS yaml keys |
| "secret not found" error in pod | Secret manifest not in kustomization resources | Add `secret.yaml` to app's `kustomization.yaml` |
| SOPS decrypt error in Flux | `sops-gpg` Secret missing or wrong key | Check `kubectl get secret sops-gpg -n flux-system` |
| Substitution works in one cluster but not another | Variable is in cluster-secrets, not common-secrets | Move to common-secrets or add to each cluster |

## Adding a New Secret

### Step 1: Add to SOPS file
```bash
# Decrypt, edit, re-encrypt
sops clusters/common/flux/vars/common-secrets.sops.yaml
# Add your key under stringData:
#   MY_NEW_SECRET: the-actual-value
# Save — sops re-encrypts automatically
```

### Step 2: Reference in your app
Choose the pattern that fits:
- **Inline config:** Use `${MY_NEW_SECRET}` directly in HelmRelease values
- **K8s Secret:** Create a `secret.yaml` with `stringData: { key: "${MY_NEW_SECRET}" }`
- **Env var:** Reference the K8s Secret via `secretKeyRef`

### Step 3: Commit and push
Flux will decrypt, substitute, and apply automatically.

## Security Notes

- SOPS key names are visible in Git (only values are encrypted) — don't put secrets in key names
- The `sops-gpg` Secret is the crown jewel — if compromised, all secrets are exposed
- Never commit decrypted values — use `sops` CLI to edit in-place
- The `substitution.flux.home.arpa/disabled: "true"` label opts a Kustomization out of substitution
- Flux substitution happens server-side — secrets never appear in Git in plaintext
