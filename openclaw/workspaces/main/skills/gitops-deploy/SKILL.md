---
name: GitOps Deploy
description: >
  End-to-end deployment workflow — commit, CI, Flux reconcile, pod restart,
  verify. Includes ConfigMap changes, Flux postBuild escaping, and SOPS
  secret management.

  Use when: You need to deploy changes to the OpenClaw pod — config updates,
  workspace changes, image rebuilds, or secret rotations. Also use when
  someone asks "how do I deploy this?" or "push this change live."

  Don't use when: You're debugging why a deployment failed (use
  flux-debugging or pod-troubleshooting). Don't use for changes to
  kubernetes-manifests repo (Dyson's pr-workflow handles that). Don't use
  for registry/image inspection (use zot-registry).

  Outputs: Deployed changes verified in the running pod. Confirmation
  includes CI status, Flux reconciliation state, pod status, and startup
  logs.
disable-model-invocation: true
requires: [kubectl, flux, sops]
---

# GitOps Deploy

## Routing

**Note:** This skill has `disable-model-invocation: true` — it won't be auto-invoked by the model. Reference it manually when needed.

### Use This Skill When
- Deploying config changes to the OpenClaw pod
- Pushing workspace file updates that need to go live
- Rebuilding and deploying the OpenClaw or workspace Docker image
- Rotating or adding secrets via SOPS
- Someone asks "deploy this" or "make this change live"
- You just merged a PR and need to roll it out

### Don't Use This Skill When
- Flux kustomization is failing to reconcile → use **flux-debugging**
- Pod is crashing after deployment → use **pod-troubleshooting**
- CI build failed → use **ci-diagnosis** (morty)
- You're inspecting images in the registry → use **zot-registry**
- You're making changes to kubernetes-manifests repo → use **pr-workflow** (dyson)
- You're only editing workspace docs with no need to deploy → just commit and push

## Full Deployment Flow

```
git commit → git push → CI builds images → Flux reconciles → pod restarts
```

### 1. Push Changes

Commit and push to `main`. Two CI pipelines may trigger depending on what changed:

- `build-openclaw.yaml` — Dockerfile.openclaw or workflow changes
- `build-workspace.yaml` — workspace/** or Dockerfile.workspace changes

### 2. Monitor CI

```bash
# List recent workflow runs
gh run list --repo keiretsu-labs/kubernetes-manifests --limit 5

# Watch a specific run
gh run watch <run-id> --repo keiretsu-labs/kubernetes-manifests

# Check if the run succeeded
gh run view <run-id> --repo keiretsu-labs/kubernetes-manifests
```

### 3. Reconcile Flux

After CI completes and images are pushed, tell Flux to pick up the new git state:

```bash
# Reconcile source + kustomization in one shot
flux reconcile kustomization openclaw --with-source

# Wait for it
flux get kustomization openclaw
```

### 4. Force Image Pull

The deployment uses `:latest` tags. Kubernetes won't re-pull unless the pod restarts:

```bash
kubectl rollout restart deployment openclaw -n openclaw
kubectl rollout status deployment openclaw -n openclaw  # Wait for this to complete!
```

⚠️ **Wait for `rollout status` to report success before checking logs.** The new pod needs 10-30s to start. Checking too early shows the old pod's logs.

### 5. Verify

```bash
kubectl get pods -n openclaw -o wide
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --tail=20
```

## ConfigMap Changes

Config lives in `kustomization/openclaw.json`, delivered via kustomize configMapGenerator.

Key rules:
- Generator uses `disableNameSuffixHash: true` — the ConfigMap name is always `openclaw-config`
- Init container copies config from ConfigMap to emptyDir (writable)
- Config changes require a pod restart to take effect (init container runs on startup)

### Flux PostBuild Escaping

Flux performs `${VAR}` substitution on all manifests. If your config contains literal `${VAR}` references (for OpenClaw's own env var substitution), you must escape them:

```
Config value:      ${MY_SECRET}
In the file:       $${MY_SECRET}
After Flux sub:    ${MY_SECRET}   ← OpenClaw resolves this at runtime
```

Double-dollar `$${}` tells Flux to emit a literal `${}` without substituting.

**Common mistake:** Forgetting to escape after editing openclaw.json. Always grep:
```bash
# These should NOT exist (Flux will eat them):
grep -n '${' kustomization/openclaw.json | grep -v '$${' 
# ^ If non-empty, you have unescaped vars that Flux will substitute incorrectly
```

## SOPS Secret Management

Secrets are encrypted with SOPS using PGP key `FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5`.

```bash
# Decrypt and view
sops -d kustomization/secret.sops.yaml

# Edit (opens in $EDITOR, re-encrypts on save)
sops kustomization/secret.sops.yaml

# Set a single value
sops --set '["stringData"]["NEW_KEY"] "value"' kustomization/secret.sops.yaml

# Verify the change
sops -d kustomization/secret.sops.yaml | yq '.stringData.NEW_KEY'
```

After modifying secrets:
1. Commit and push the encrypted file
2. Flux decrypts during reconciliation using its SOPS provider
3. Restart the pod if the secret is consumed via `envFrom`

## Security Notes

- **Never** commit unencrypted secrets — always use SOPS
- **Never** `docker push` to the registry — only `skopeo copy docker-archive:`
- Verify `$${VAR}` escaping before pushing config changes
- Review SOPS diffs carefully — `sops -d` both old and new to compare plaintext

## Quick Deploy Checklist

1. ☐ Make changes to config/manifests/workspace
2. ☐ Validate: `jq . openclaw.json`, `kustomize build kustomization/`
3. ☐ Check escaping: `grep -n '${' openclaw.json | grep -v '$${' ` → should be empty
4. ☐ `git add && git commit && git push`
5. ☐ Wait for CI (if image changes): `gh run watch`
6. ☐ `flux reconcile kustomization openclaw --with-source`
7. ☐ `kubectl rollout restart deployment openclaw -n openclaw` (if images changed)
8. ☐ `kubectl get pods -n openclaw` — verify Running
9. ☐ `kubectl logs ... -c openclaw --tail=20` — verify startup

## Artifact Handoff

Write deployment verification results to `/tmp/outputs/deploy-verification.md` for complex deployments that need audit trails.
