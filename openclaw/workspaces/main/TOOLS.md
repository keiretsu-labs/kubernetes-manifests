# Workspace Tools

All tools are installed at `/usr/local/bin/` and on `$PATH`. The workspace has a ServiceAccount (`tailscale`) with RBAC configured for in-cluster access to the `openclaw` namespace.

## Skills

Skills are higher-level knowledge packages that build on the CLI tools below. Check `workspace/skills/` for structured guides on:
- **cluster-context** — Pod architecture, volumes, networking, secrets
- **flux-debugging** — Flux reconciliation troubleshooting chain
- **pod-troubleshooting** — Container failure diagnosis
- **gitops-deploy** — End-to-end deployment workflow
- **zot-registry** — OCI registry operations
- **memory-management** — Session and context management
- **openclaw-docs** — OpenClaw documentation lookup via web_fetch

Use skills first for common tasks — they encode tested diagnostic sequences and known gotchas.

## Scrapling MCP (Web Scraping — preferred over browser)

Scrapling runs as a sidecar MCP server on `localhost:8000`. Access it via the `mcp` tool. **Always prefer Scrapling over the browser tool for fetching web content** — it's faster, more reliable, returns clean markdown, and doesn't get blocked by CAPTCHAs.

### Available tools

| Tool | Use case |
|------|----------|
| `get` | Fast HTTP-only fetch (no JS). Best for static pages, APIs, simple HTML. |
| `fetch` | Playwright-based with full JS execution. Handles SPAs, dynamic content. |
| `stealthy_fetch` | Anti-bot bypass mode. Use for sites that block scrapers (Google, Cloudflare-protected). |
| `bulk_get` | Batch HTTP fetch for multiple URLs at once. |
| `bulk_fetch` | Batch Playwright fetch for multiple URLs. |
| `bulk_stealthy_fetch` | Batch anti-bot fetch for multiple URLs. |

### Quick reference

```
# List all Scrapling tools
mcp action=list

# Fetch a page (with JS support)
mcp action=call server=scrapling tool=fetch args={"url":"https://example.com"}

# Fast HTTP-only fetch (no JS, faster)
mcp action=call server=scrapling tool=get args={"url":"https://example.com"}

# Anti-bot fetch (for protected sites like Google, Cloudflare)
mcp action=call server=scrapling tool=stealthy_fetch args={"url":"https://example.com"}

# Extract specific content with CSS selector
mcp action=call server=scrapling tool=fetch args={"url":"https://example.com","css_selector":"article"}

# Get raw HTML instead of markdown
mcp action=call server=scrapling tool=fetch args={"url":"https://example.com","extraction_type":"html"}
```

### When to use which tool

- **`get`** — Default for most pages. Fast, lightweight, no browser overhead.
- **`fetch`** — When `get` returns incomplete content (JS-rendered pages, SPAs).
- **`stealthy_fetch`** — When `fetch` gets blocked (403, CAPTCHA, bot detection).
- **`bulk_*`** — When scraping multiple URLs in one task. More efficient than sequential calls.

### Notes

- Returns structured JSON with `status`, `content` (markdown by default), and `url`
- Supports `extraction_type`: `markdown` (default), `html`, `text`
- Supports `css_selector` for targeted extraction
- Supports custom `headers` and `cookies` for authenticated requests
- The browser tool is disabled — Scrapling replaces it for all web content tasks

## gh

GitHub CLI. Authenticated as `rajsinghtechbot` via GITHUB_TOKEN env var.

```bash
# Check CI runs
gh run list --repo keiretsu-labs/kubernetes-manifests --limit 5
gh run view <run-id> --repo keiretsu-labs/kubernetes-manifests
gh run watch <run-id> --repo keiretsu-labs/kubernetes-manifests

# Clone and push
gh repo clone keiretsu-labs/kubernetes-manifests -- /tmp/workspace-edit

# Issues and PRs
gh issue list --repo keiretsu-labs/kubernetes-manifests
gh pr list --repo keiretsu-labs/kubernetes-manifests
gh pr create --title "..." --body "..."
```

## git

Authenticated via credential helper using GITHUB_TOKEN. Commits as `rajsinghtechbot <king360raj@gmail.com>`.

```bash
git clone https://github.com/keiretsu-labs/kubernetes-manifests.git /tmp/workspace-edit
# make changes...
git add <files>
git commit -m "description"
git push
```

## kubectl

Kubernetes cluster management. In-cluster config is automatic.

```bash
# Pod status
kubectl get pods -n openclaw
kubectl get pods -n openclaw -o wide
kubectl describe pod -l app.kubernetes.io/name=openclaw -n openclaw

# Container logs
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --tail=100
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c tailscale --tail=50
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c init-workspace

# Deployment status
kubectl get deployment openclaw -n openclaw
kubectl rollout status deployment openclaw -n openclaw
kubectl rollout restart deployment openclaw -n openclaw

# Config inspection
kubectl get configmap openclaw-config -n openclaw -o yaml
kubectl get secret openclaw-secrets -n openclaw -o yaml

# Events (sorted by time)
kubectl get events -n openclaw --sort-by='.lastTimestamp'

# Resources in the namespace
kubectl get all -n openclaw

# Check ImageVolume reference
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o jsonpath='{.items[0].spec.volumes[?(@.name=="workspace")].image}'

# Check pull secret
kubectl get secret zot-pull-secret -n openclaw -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .

# Exec into the main container
kubectl exec -it deployment/openclaw -c openclaw -n openclaw -- /bin/sh

# Check DNS resolution for LLM backend
kubectl exec deployment/openclaw -c openclaw -n openclaw -- nslookup stpetersburg-llama-cpp
```

## flux

Flux CD GitOps toolkit. Used to inspect and manage the GitOps reconciliation.

```bash
# Overall status of Flux kustomizations
flux get kustomization -A

# Git source status
flux get source git -A

# OCI source status (if any)
flux get source oci -A

# Force reconciliation (pulls latest from git + reapplies)
flux reconcile kustomization <name> --with-source

# Suspend/resume reconciliation (useful during debugging)
flux suspend kustomization <name>
flux resume kustomization <name>

# Check Flux controller logs
kubectl logs -n flux-system deployment/kustomize-controller --tail=50
kubectl logs -n flux-system deployment/source-controller --tail=50

# Flux events
flux events -A --for Kustomization/<name>
```

## helm

Kubernetes package manager. Available for inspecting Helm releases in the cluster.

```bash
# List releases across namespaces
helm list -A

# Check release status
helm status <release> -n <namespace>

# Show values of a release
helm get values <release> -n <namespace>
```

## kustomize

Preview what Flux will apply from the repo's kustomization directory.

```bash
# Build and preview the full rendered output
# NOTE: this requires the repo to be cloned. The workspace content doesn't include kustomization/
# but you can use it to validate kustomize overlays if files are available.
kustomize build <path>

# With variable substitution preview (manual)
kustomize build <path> | yq
```

## sops

Secrets encryption and decryption. The SOPS config (`.sops.yaml`) uses PGP key `FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5`.

```bash
# Decrypt a SOPS-encrypted file (requires the PGP private key)
sops -d secret.sops.yaml

# Encrypt a plaintext YAML file
sops -e secret.yaml > secret.sops.yaml

# Edit an encrypted file in-place (opens in $EDITOR)
sops secret.sops.yaml

# Rotate encryption keys
sops --rotate -i secret.sops.yaml

# Show metadata without decrypting
sops filestatus secret.sops.yaml
```

Note: Decryption requires the PGP private key to be available in the GPG keyring. In the cluster, Flux handles decryption via its SOPS provider. You likely cannot decrypt secrets interactively from inside this pod unless the key is imported.

## yq

YAML processor. Useful for inspecting and transforming Kubernetes manifests.

```bash
# Pretty-print YAML
yq . file.yaml

# Extract a specific field
kubectl get deployment openclaw -n openclaw -o yaml | yq '.spec.template.spec.containers[].image'

# List all container images in a pod
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o yaml | yq '.items[0].spec.containers[].image'

# Check init container images
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o yaml | yq '.items[0].spec.initContainers[].image'
```

## jq

JSON processor. Useful for working with kubectl JSON output and API responses.

```bash
# Pretty-print JSON
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | jq '.items[0].status.phase'

# Get container statuses
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | jq '.items[0].status.containerStatuses[] | {name, ready, restartCount, state}'

# Get init container statuses
kubectl get pod -l app.kubernetes.io/name=openclaw -n openclaw -o json | jq '.items[0].status.initContainerStatuses[] | {name, ready, state}'

# Parse events
kubectl get events -n openclaw -o json | jq '.items | sort_by(.lastTimestamp) | .[-10:] | .[] | {type, reason, message, lastTimestamp}'
```

## Cross-Cluster kubectl

The workspace includes a multi-cluster kubeconfig at `kustomization/kubeconfig.yaml` with contexts for `ottawa`, `robbinsdale`, and `stpetersburg`.

### Cluster Alias Functions

Add these functions to your shell for quick cluster switching:

```bash
# Add to ~/.bashrc or run interactively
alias kx-ottawa='kubectl config use-context ottawa'
alias kx-robbinsdale='kubectl config use-context robbinsdale'
alias kx-stpetersburg='kubectl config use-context stpetersburg'

# List all cluster contexts
alias kx-all='kubectl config get-contexts -o name'

# Quick switch (kx <name>)
kx() {
  case "$1" in
    ottawa|robbinsdale|stpetersburg) kubectl config use-context "$1" ;;
    *) echo "Usage: kx {ottawa|robbinsdale|stpetersburg}" ;;
  esac
}
```

### Cross-Cluster Operations

```bash
# Export kubeconfig for all clusters
export KUBECONFIG=/home/node/.openclaw/kubeconfig.yaml

# Query all clusters at once
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  kubectl --context=$ctx get pods -n openclaw -o wide 2>/dev/null
done

# Get Flux status across all clusters
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  flux --context=$ctx get kustomization -A 2>/dev/null | grep -E "(NAME|openclaw)"
done

# Check warning events across all clusters
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  kubectl --context=$ctx get events -n openclaw --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -5
done

# Full cross-cluster audit script
cross-cluster-audit() {
  for ctx in ottawa robbinsdale stpetersburg; do
    echo "=========================================="
    echo "CLUSTER: $ctx"
    echo "=========================================="
    echo "--- Pods ---"
    kubectl --context=$ctx get pods -n openclaw -o wide 2>/dev/null || echo "Cluster unreachable"
    echo "--- Flux ---"
    flux --context=$ctx get kustomization -A 2>/dev/null | grep openclaw || echo "Flux error"
    echo "--- Recent Warnings ---"
    kubectl --context=$ctx get events -n openclaw --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -3
    echo ""
  done
}
```

### Applying to Remote Clusters

```bash
# Apply kustomization to a specific remote cluster
kubectl --context=robbinsdale apply -k kustomization/
kubectl --context=stpetersburg apply -k kustomization/

# Use flux reconcile with context
flux --context=robbinsdale reconcile kustomization openclaw --with-source
flux --context=stpetersburg reconcile kustomization openclaw --with-source
```

## Quick Health Check

Run these in sequence to get a full picture of the deployment:

```bash
kubectl get pods -n openclaw -o wide
kubectl get deployment openclaw -n openclaw
kubectl get events -n openclaw --sort-by='.lastTimestamp' | tail -20
flux get kustomization -A | grep openclaw
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --tail=20
```
