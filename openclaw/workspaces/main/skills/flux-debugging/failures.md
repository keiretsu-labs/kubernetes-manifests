# Flux Failure Reference

## Stale Revision

Source shows an old commit hash. Either the repo webhook didn't fire or source-controller can't fetch.

```bash
# Check source-controller logs
kubectl logs -n flux-system deployment/source-controller --tail=50

# Force source fetch
flux reconcile source git openclaw-workspace

# Verify new revision appears
flux get source git openclaw-workspace
```

## Failed Apply

Kustomization is `Ready=False` with an apply error. Usually a manifest syntax issue or missing resource.

```bash
# Get the error message
flux get kustomization openclaw-workspace -o yaml | yq '.status.conditions[] | select(.type=="Ready")'

# Preview what kustomize would render (if repo is available)
kustomize build ./kustomization

# Force re-apply after fixing
flux reconcile kustomization openclaw-workspace --with-source
```

## Dependency Not Ready

Kustomization depends on another that hasn't reconciled yet.

```bash
# List all kustomizations and their status
flux get kustomization -A

# Check the dependency
flux get kustomization <dependency-name>

# Reconcile the dependency first
flux reconcile kustomization <dependency-name> --with-source
```

## SOPS Decrypt Error

Secret decryption failed — usually a missing or wrong PGP key.

```bash
# Check kustomize-controller logs for decrypt errors
kubectl logs -n flux-system deployment/kustomize-controller --tail=50 | grep -i sops

# Verify the SOPS secret exists in flux-system
kubectl get secret sops-gpg -n flux-system

# Check which PGP key the .sops.yaml expects
# Expected: FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5
```
