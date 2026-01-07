# Tailscale Workload Identity Federation on GKE

Authenticate Tailscale containers using GKE's native OIDC tokens instead of auth keys.

| Approach | GCP IAM Required | Best For |
|----------|------------------|----------|
| **Direct OIDC** (this guide) | No | Tailscale-only authentication |
| **GCP Workload Identity** | Yes | When also accessing GCP APIs |

---

## Direct OIDC Approach

### 1. Get GKE OIDC Issuer URL

```bash
gcloud container clusters describe <CLUSTER_NAME> \
  --region <REGION> \
  --format='value(selfLink)'
```

### 2. Create Federated Credential in Tailscale Admin

Go to **Settings > OAuth clients > Federated credentials** and configure:

- **Issuer type**: Custom
- **Issuer URL**: GKE issuer URL from step 1
- **Subject claim**: `system:serviceaccount:<namespace>:<serviceaccount-name>`
- **Tags**: Tags the device should receive
- **Scopes**: `auth_keys`

Note the **Client ID** and **Audience** values.

### 3. Deploy

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tailscale
  namespace: tailscale-testing
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tailscale-wif
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tailscale-wif
  template:
    metadata:
      labels:
        app: tailscale-wif
    spec:
      serviceAccountName: tailscale
      initContainers:
        - name: sysctler
          image: ghcr.io/tailscale/tailscale:latest
          command: ["/bin/sh", "-c"]
          args: ["sysctl -w net.ipv4.ip_forward=1"]
          securityContext:
            privileged: true
      containers:
        - name: tailscale
          image: ghcr.io/tailscale/tailscale:latest
          securityContext:
            privileged: true
          env:
            - name: TS_KUBE_SECRET
              value: ""
            - name: TS_USERSPACE
              value: "false"
            - name: TS_ACCEPT_DNS
              value: "true"
            - name: TS_EXTRA_ARGS
              value: "--advertise-tags=tag:k8s --client-id=<CLIENT_ID> --id-token=file:/var/run/secrets/tailscale/serviceaccount/token"
            - name: TS_HOSTNAME
              value: "my-gke-workload"
          volumeMounts:
            - name: tailscale-token
              mountPath: /var/run/secrets/tailscale/serviceaccount
              readOnly: true
      volumes:
        - name: tailscale-token
          projected:
            sources:
              - serviceAccountToken:
                  audience: "<AUDIENCE>"
                  expirationSeconds: 3600
                  path: token
```

Replace `<CLIENT_ID>` and `<AUDIENCE>` with values from Tailscale admin.

### Verify

```bash
kubectl logs -l app=tailscale-wif | grep machineAuthorized
# Should show: machineAuthorized=true; authURL=false
```

---

## GCP Workload Identity Approach

Use this if you have GCP IAM permissions and want Google-signed tokens.

**Important**: This approach requires fetching the token from the **GCP metadata server**, NOT using K8s projected tokens. The K8s projected token has the GKE cluster as issuer, but GCP Workload Identity tokens have `https://accounts.google.com` as issuer.

### 1. Enable Workload Identity

```bash
gcloud container clusters update <CLUSTER_NAME> \
  --region <REGION> \
  --workload-pool=<PROJECT_ID>.svc.id.goog
```

### 2. Create and Bind GCP Service Account

```bash
# Create GCP service account
gcloud iam service-accounts create tailscale-wif --project=<PROJECT_ID>

# Bind K8s SA to GCP SA (requires iam.serviceAccounts.setIamPolicy permission)
gcloud iam service-accounts add-iam-policy-binding \
  tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:<PROJECT_ID>.svc.id.goog[<NAMESPACE>/<K8S_SA_NAME>]"
```

### 3. Configure Tailscale Federated Credential

- **Issuer type**: Google Cloud Platform
- **Issuer URL**: `https://accounts.google.com`
- **Subject claim**: `tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com` (the GCP SA email)
- **Tags**: Tags the device should receive
- **Scopes**: `auth_keys`

### 4. Deploy with Metadata Server Token Fetch

**Critical**: You must fetch the token from the GCP metadata server, not use K8s projected tokens.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tailscale
  namespace: tailscale-testing
  annotations:
    iam.gke.io/gcp-service-account: tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tailscale-wif-gcp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tailscale-wif-gcp
  template:
    metadata:
      labels:
        app: tailscale-wif-gcp
    spec:
      serviceAccountName: tailscale
      initContainers:
        - name: sysctler
          image: ghcr.io/tailscale/tailscale:latest
          command: ["/bin/sh", "-c"]
          args: ["sysctl -w net.ipv4.ip_forward=1"]
          securityContext:
            privileged: true
        - name: fetch-gcp-token
          image: curlimages/curl:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              # Fetch Google-signed identity token from metadata server
              # This token has issuer: https://accounts.google.com
              # and subject: <GCP_SA_EMAIL>
              curl -s -H "Metadata-Flavor: Google" \
                "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=api.tailscale.com/<CLIENT_ID>" \
                > /var/run/secrets/tailscale/idtoken/token
          volumeMounts:
            - name: tailscale-token
              mountPath: /var/run/secrets/tailscale/idtoken
      containers:
        - name: tailscale
          image: ghcr.io/tailscale/tailscale:latest
          securityContext:
            privileged: true
          env:
            - name: TS_KUBE_SECRET
              value: ""
            - name: TS_USERSPACE
              value: "false"
            - name: TS_ACCEPT_DNS
              value: "true"
            - name: TS_EXTRA_ARGS
              value: "--advertise-tags=tag:k8s --client-id=<CLIENT_ID> --id-token=file:/var/run/secrets/tailscale/idtoken/token"
            - name: TS_HOSTNAME
              value: "my-gke-workload-gcp"
          volumeMounts:
            - name: tailscale-token
              mountPath: /var/run/secrets/tailscale/idtoken
              readOnly: true
      volumes:
        - name: tailscale-token
          emptyDir: {}
```

### Token Refresh Consideration

The init container only fetches the token once at pod startup. For long-running pods, consider using a sidecar that periodically refreshes the token, or rely on pod restarts.

---

## Key Differences Between Approaches

| Aspect | Direct OIDC | GCP Workload Identity |
|--------|-------------|----------------------|
| Token source | K8s projected SA token | GCP metadata server |
| Issuer | `https://container.googleapis.com/v1/projects/.../clusters/...` | `https://accounts.google.com` |
| Subject | `system:serviceaccount:<ns>:<sa>` | `<sa>@<project>.iam.gserviceaccount.com` |
| IAM required | No | Yes (`iam.serviceAccounts.setIamPolicy`) |
| Token refresh | Automatic by kubelet | Manual (sidecar or pod restart) |
| Best for | Simple Tailscale-only auth | When also using GCP APIs |

## Debugging

Decode and inspect your token:
```bash
# For K8s projected token (Direct OIDC) - path: /var/run/secrets/tailscale/serviceaccount/token
kubectl exec -it <pod> -- cat /var/run/secrets/tailscale/serviceaccount/token | \
  cut -d. -f2 | base64 -d 2>/dev/null | jq .

# Expected for Direct OIDC:
# "iss": "https://container.googleapis.com/v1/projects/<project>/locations/<region>/clusters/<cluster>"
# "sub": "system:serviceaccount:<namespace>:<sa-name>"

# For GCP Workload Identity - path: /var/run/secrets/tailscale/idtoken/token
kubectl exec -it <pod> -- cat /var/run/secrets/tailscale/idtoken/token | \
  cut -d. -f2 | base64 -d 2>/dev/null | jq .

# Expected for GCP Workload Identity:
# "iss": "https://accounts.google.com"
# "sub": "<sa-name>@<project>.iam.gserviceaccount.com"
```
