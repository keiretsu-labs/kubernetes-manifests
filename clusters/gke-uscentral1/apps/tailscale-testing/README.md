 Tailscale Workload Identity Federation on GKE

This guide shows how to authenticate Tailscale containers to your tailnet using GKE's native OIDC tokens instead of auth keys or OAuth secrets.

Overview

There are two approaches to Workload Identity Federation on GKE:

| Approach | GCP IAM Required | Best For |
|----------|------------------|----------|
| **Direct OIDC** (this guide) | No | Tailscale-only authentication |
| **GCP Workload Identity** | Yes | When also accessing GCP APIs |

This guide covers the **Direct OIDC** approach which requires no GCP IAM permissions.

Prerequisites

- GKE cluster (any version with projected service account tokens)
- Tailscale v1.90.1+ container image
- Admin access to Tailscale admin console

Step 1: Get Your GKE OIDC Issuer URL

```bash
gcloud container clusters describe <CLUSTER_NAME> \
  --region <REGION> \
  --format='value(selfLink)'
```

This returns something like:
```
https://container.googleapis.com/v1/projects/<PROJECT>/locations/<REGION>/clusters/<CLUSTER>
```

Step 2: Create Federated Credential in Tailscale Admin

1. Go to Settings > OAuth clients > Federated credentials
2. Click Add federated credential
3. Configure:
   - Issuer type: Custom
   - Issuer URL: Your GKE issuer URL from Step 1
   - Subject claim: `system:serviceaccount:<namespace>:<serviceaccount-name>`
     - Example: `system:serviceaccount:tailscale-testing:tailscale`
   - Tags: Select tags the device should receive (e.g., `tag:k8s`)
   - Scopes: `auth_keys` (required)

4. Save and note the Client ID and Audience values

Step 3: Create Kubernetes Resources

ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tailscale
  namespace: tailscale-testing
```

Deployment

```yaml
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
          args:
            - sysctl -w net.ipv4.ip_forward=1
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

Replace:
- `<CLIENT_ID>`: From Tailscale admin (e.g., `TbqNGJkY5611CNTRL-kF8VA8GYua11CNTRL`)
- `<AUDIENCE>`: From Tailscale admin (e.g., `api.tailscale.com/TbqNGJkY5611CNTRL-kF8VA8GYua11CNTRL`)

How It Works

1. GKE projects a signed JWT token into the pod at the specified path
2. The token contains the service account identity as the subject claim
3. Tailscale exchanges this token with the control plane
4. Control plane validates the token signature against GKE's OIDC discovery endpoint
5. If the subject matches the configured federated credential, the device is authorized

Key Points

- No secrets required: The OIDC token is automatically rotated by Kubernetes
- Tags must match: The `--advertise-tags` must be a subset of tags configured in the federated credential
- Subject format: Always `system:serviceaccount:<namespace>:<name>`
- Use TS_EXTRA_ARGS: The `--client-id` and `--id-token` flags must be passed via `TS_EXTRA_ARGS`, not as separate env vars

Verification

Check logs for successful authentication:
```bash
kubectl logs -l app=tailscale-wif
```

Look for:
```
machineAuthorized=true; authURL=false
active login: my-gke-workload.<tailnet>.ts.net
Switching ipn state Starting -> Running
```

Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `authURL=true` / interactive login prompt | WIF not configured or misconfigured | Verify issuer URL, subject claim, and audience match exactly |
| Token validation failed | Wrong audience | Ensure `audience` in projected token matches Tailscale config |
| Unauthorized tags | Tag mismatch | Tags in `--advertise-tags` must be allowed in federated credential |
| Token file not found | Volume not mounted | Check volumeMounts path matches `--id-token=file:` path |

Alternative: GCP Workload Identity Approach

If you have GCP IAM permissions and want to use a GCP service account (useful if your workload also needs GCP API access), you can use GCP Workload Identity instead:

1. Enable Workload Identity on GKE

```bash
gcloud container clusters update <CLUSTER_NAME> \
  --region <REGION> \
  --workload-pool=<PROJECT_ID>.svc.id.goog
```

2. Create a GCP Service Account

```bash
gcloud iam service-accounts create tailscale-wif \
  --display-name="Tailscale WIF"
```

3. Bind K8s SA to GCP SA

```bash
gcloud iam service-accounts add-iam-policy-binding \
  tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:<PROJECT_ID>.svc.id.goog[<NAMESPACE>/<K8S_SA_NAME>]"
```

4. Annotate the Kubernetes ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tailscale
  namespace: tailscale-testing
  annotations:
    iam.gke.io/gcp-service-account: tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com
```

5. Configure Tailscale Federated Credential

In Tailscale admin, use:
- **Issuer**: `https://accounts.google.com`
- **Subject**: The GCP service account email (e.g., `tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com`)

6. Deploy with GCP Workload Identity

```yaml
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
          args:
            - sysctl -w net.ipv4.ip_forward=1
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
                  audience: "<GCP_SA_EMAIL>"  # e.g., tailscale-wif@my-project.iam.gserviceaccount.com
                  expirationSeconds: 3600
                  path: token
```

Replace:
- `<CLIENT_ID>`: From Tailscale admin federated credential
- `<GCP_SA_EMAIL>`: Your GCP service account email (e.g., `tailscale-wif@<PROJECT_ID>.iam.gserviceaccount.com`)

> **Note**: The Direct OIDC approach (main guide above) is simpler and recommended unless you specifically need GCP Workload Identity for other GCP integrations.
