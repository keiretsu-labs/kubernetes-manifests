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

Use this if you have GCP IAM permissions and need GCP API access.

### 1. Enable Workload Identity

```bash
gcloud container clusters update <CLUSTER_NAME> \
  --region <REGION> \
  --workload-pool=<PROJECT_ID>.svc.id.goog
```

### 2. Create and Bind GCP Service Account

```bash
gcloud iam service-accounts create tailscale-wif

gcloud iam service-accounts add-iam-policy-binding \
  tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:<PROJECT_ID>.svc.id.goog[<NAMESPACE>/<K8S_SA_NAME>]"
```

### 3. Configure Tailscale Federated Credential

- **Issuer**: `https://accounts.google.com`
- **Subject**: `tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com`

### 4. Deploy

Same as Direct OIDC, but:
- Add annotation to ServiceAccount: `iam.gke.io/gcp-service-account: tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com`
- Use GCP SA email as `audience` in projected token
