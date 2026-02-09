# Zot OCI Registry

Self-hosted OCI-compliant container registry deployed via Helm across all clusters.

## Access

Each cluster exposes the registry at `oci.<CLUSTER_DOMAIN>` (e.g. `oci.killinit.cc` for Ottawa).

The HTTPRoute is attached to the `ts`, `private`, and `public` gateways.

## Authentication

All access requires htpasswd basic auth. Anonymous access is disabled.

**Username:** `admin`

**Credentials** are stored in `common-secrets` (SOPS-encrypted) under the key `COMMON_OCI`. This contains the bcrypt htpasswd entry which is injected into the Helm release via Flux variable substitution (`${COMMON_OCI}`).

To retrieve the plaintext password:

```bash
sops -d clusters/common/flux/vars/common-secrets.sops.yaml | grep COMMON_OCI
```

The value is in `user:$2y$...` htpasswd format. The plaintext password used to generate it is not stored in the secret — if you need to rotate credentials, generate a new htpasswd entry:

```bash
htpasswd -nbB admin '<new-password>'
```

Then update `COMMON_OCI` in `common-secrets.sops.yaml` with the new htpasswd line and re-encrypt.

## Usage

### Login

```bash
crane auth login oci.<CLUSTER_DOMAIN> -u admin -p <password>
# or
docker login oci.<CLUSTER_DOMAIN> -u admin -p <password>
```

### Push

```bash
crane copy <source-image> oci.<CLUSTER_DOMAIN>/<repo>/<name>:<tag>
```

### Pull

```bash
crane pull oci.<CLUSTER_DOMAIN>/<repo>/<name>:<tag> output.tar
```

### Browse catalog

```bash
curl -su admin:<password> https://oci.<CLUSTER_DOMAIN>/v2/_catalog
```

## Architecture

```
common-secrets (SOPS)
  └── COMMON_OCI ─── Flux substitution ──▶ HelmRelease secretFiles.htpasswd
                                               │
HelmRepository (zot)                           │
  └── HelmRelease ◀───────────────────────────┘
        ├── StatefulSet (1 replica, 20Gi PVC)
        ├── Service (ClusterIP:5000)
        ├── ConfigMap (zot config w/ htpasswd auth)
        └── Secret (htpasswd file)

HTTPRoute (oci.${CLUSTER_DOMAIN})
  ├── Gateway: ts
  ├── Gateway: private
  └── Gateway: public
```

## Files

| File | Purpose |
|------|---------|
| `ks.yaml` | Flux Kustomization targeting `./app` |
| `namespace.yaml` | Namespace with prune disabled |
| `app/helmrelease.yaml` | Zot Helm chart (v0.1.98) with auth config |
| `app/httproute.yaml` | Gateway API route for `oci.${CLUSTER_DOMAIN}` |

## Notes

- The bcrypt `$` characters in `COMMON_OCI` are safe from Flux envsubst mangling because envsubst replaces `${COMMON_OCI}` in a single pass and does not re-process the substituted value.
- The Helm chart's `secretFiles` creates a Kubernetes Secret (`zot-secret`) mounted at `/secret/htpasswd`.
- Storage is a 20Gi PVC per cluster (`ReadWriteOnce`). Images persist across pod restarts.
- The `defaultPolicy: []` in accessControl means no anonymous access to any repository.
