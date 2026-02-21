---
name: Zot Registry
description: >
  OCI registry operations — image inspection, push troubleshooting, multi-arch
  manifests, pull secret verification.

  Use when: You need to inspect images in the registry, troubleshoot
  "manifest invalid" errors, debug ImagePullBackOff caused by registry issues,
  verify pull secrets, or check if a new image was pushed after CI.

  Don't use when: The pod is crashing for non-image reasons (use
  pod-troubleshooting). Don't use for Flux reconciliation failures (use
  flux-debugging). Don't use for CI build failures before the push step
  (use ci-diagnosis). Don't use for deploying changes end-to-end (use
  gitops-deploy).

  Outputs: Image manifest details, tag listings, digest verification,
  pull secret validation results, or push troubleshooting diagnosis.
requires: [kubectl, crane, skopeo]
---

# Zot Registry

Registry: `oci.killinit.cc`

## Routing

### Use This Skill When
- Checking if an image exists or was recently pushed
- Debugging "manifest invalid" errors after a push
- Pod has ImagePullBackOff and you suspect registry/auth issues
- Verifying pull secrets are correct
- Inspecting image layers, digests, or multi-arch manifests
- Someone asks "is the latest image pushed?" or "what version is running?"

### Don't Use This Skill When
- Pod is crashing (CrashLoopBackOff, OOMKilled) → use **pod-troubleshooting**
- Flux can't reconcile → use **flux-debugging**
- CI workflow failed during build (before push) → use **ci-diagnosis**
- You need to deploy end-to-end → use **gitops-deploy**
- Storage/PVC issues → use **storage-ops**
- You're reviewing code changes → use **code-review**

## Critical: Push Method

Zot rejects manifests from `docker push`, `crane push`, and buildx `--push`. The **only** working push method is:

```bash
skopeo copy docker-archive:<file>.tar docker://oci.killinit.cc/<repo>/<image>:<tag>
```

This is handled automatically by CI workflows. Never change the push method.

⚠️ **If someone suggests using `docker push` or `crane push` — stop them.** It will produce a "manifest invalid" error and the image won't be usable.

## Image Inspection

```bash
# Check if an image exists and view its manifest
crane manifest oci.killinit.cc/openclaw/openclaw:latest | jq .
crane manifest oci.killinit.cc/openclaw/workspace:latest | jq .

# Get the digest
crane digest oci.killinit.cc/openclaw/openclaw:latest
crane digest oci.killinit.cc/openclaw/workspace:latest

# List tags
crane ls oci.killinit.cc/openclaw/openclaw
crane ls oci.killinit.cc/openclaw/workspace

# Full inspect (config + layers)
skopeo inspect docker://oci.killinit.cc/openclaw/openclaw:latest
```

## Multi-Arch Manifests

Per-arch images are pushed individually, then combined:

```bash
# After pushing amd64 and arm64 images separately via skopeo:
crane index append \
  --manifest oci.killinit.cc/openclaw/openclaw:<sha>-amd64 \
  --manifest oci.killinit.cc/openclaw/openclaw:<sha>-arm64 \
  --tag oci.killinit.cc/openclaw/openclaw:<sha> \
  --tag oci.killinit.cc/openclaw/openclaw:latest
```

## Authentication

```bash
# Login (credentials from Zot secrets)
crane auth login oci.killinit.cc -u <username> -p <password>

# Skopeo uses --creds or --authfile
skopeo inspect docker://oci.killinit.cc/openclaw/openclaw:latest --creds user:pass
```

In-cluster, pull credentials come from the `zot-pull-secret` imagePullSecret:

```bash
# Verify pull secret
kubectl get secret zot-pull-secret -n openclaw -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
```

## Troubleshooting

### "manifest invalid" on Push

**Cause:** Using `docker push` or `crane push` instead of `skopeo copy docker-archive:`.
**Fix:** Only push via `skopeo copy docker-archive:<file>.tar docker://oci.killinit.cc/...`
**Prevention:** This is enforced in CI. Never modify the push step in GitHub Actions.

### ImagePullBackOff in Cluster

```bash
# Check pod events
kubectl describe pod -l app.kubernetes.io/name=openclaw -n openclaw | grep -A3 "Failed"

# Verify the image tag exists
crane ls oci.killinit.cc/openclaw/openclaw

# Verify pull secret is correct
kubectl get secret zot-pull-secret -n openclaw -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq '.auths'

# Test pull manually
skopeo inspect docker://oci.killinit.cc/openclaw/openclaw:latest
```

### Stale Image After CI

Kubernetes caches `:latest` tags. Force a re-pull:

```bash
kubectl rollout restart deployment openclaw -n openclaw
```

The workspace ImageVolume uses `pullPolicy: Always`, so it re-pulls on every pod start.

### Image Exists but Wrong Architecture

```bash
# Check what architectures are in the manifest
crane manifest oci.killinit.cc/openclaw/openclaw:latest | jq '.manifests[]? | {platform, digest}'

# If single-arch, check which one
skopeo inspect docker://oci.killinit.cc/openclaw/openclaw:latest | jq '.Architecture'
```

## Security Notes

- Pull secrets contain registry credentials — never log them in plain text
- Image digests are the only tamper-proof references — use digests for security-critical verification
- CI workflows have write access to the registry via GitHub secrets — review workflow changes carefully

## Artifact Handoff

Write image inspection results to `/tmp/outputs/registry-check.md` when diagnosing complex multi-image or multi-arch issues.
