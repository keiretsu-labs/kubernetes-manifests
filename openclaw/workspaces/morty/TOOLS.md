# Tools

All tools at `/usr/local/bin/`. Authenticated as `rajsinghtechbot` via GITHUB_TOKEN.

## gh

```bash
# Clone repos
gh repo clone rajsinghtech/openclaw-workspace -- /tmp/oc-audit

# Check CI status
gh run list --repo rajsinghtech/openclaw-workspace --limit 5
gh run view <id> --repo rajsinghtech/openclaw-workspace

# Create PRs (for non-trivial changes)
gh pr create --title "fix: ..." --body "..."
```

## git

```bash
git clone https://github.com/rajsinghtech/openclaw-workspace.git /tmp/oc-audit
git add <files> && git commit -m "fix: ..." && git push
```

## Validation

```bash
# JSON
jq . <file.json> > /dev/null

# YAML
yq . <file.yaml> > /dev/null

# Kustomize render
kustomize build kustomization/
```

## Cluster Aliases (Cross-Cluster Ergonomics)

The workspace includes a multi-cluster kubeconfig at `kustomization/kubeconfig.yaml`. Use these patterns for cross-cluster operations:

### Cluster Context Switch

```bash
# Switch to a specific cluster context (from kubeconfig)
kubectl config use-context <context-name>

# Available contexts: ottawa, robbinsdale, stpetersburg
kubectl config use-context ottawa
kubectl config use-context robbinsdale
kubectl config use-context stpetersburg
```

### Cluster-Scoped kubectl Shortcuts

```bash
# Use -c/--cluster flag with kubeconfig path (set KUBECONFIG env var)
export KUBECONFIG=/home/node/.openclaw/kubeconfig.yaml

# Query all clusters at once (bash loop)
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  kubectl --context=$ctx get pods -n openclaw -o wide 2>/dev/null
done

# Get Flux status across all clusters
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  flux --context=$ctx get kustomization -A 2>/dev/null | grep -E "(NAME|openclaw)"
done

# Check events across all clusters
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  kubectl --context=$ctx get events -n openclaw --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -5
done
```

### Cross-Cluster Health Check Script

```bash
# Full cross-cluster audit (run this to check all clusters)
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
```

### Applying Manifests to Remote Clusters

```bash
# Apply kustomization to a specific remote cluster
kubectl --context=robbinsdale apply -k kustomization/
kubectl --context=stpetersburg apply -k kustomization/

# Or use flux reconcile with context
flux --context=robbinsdale reconcile kustomization openclaw --with-source
```

## kubectl (Current Cluster)

```bash
# Pod status
kubectl get pods -n openclaw -o wide

# Container logs
kubectl logs -l app.kubernetes.io/name=openclaw -n openclaw -c openclaw --tail=50

# Flux status
flux get kustomization -A | grep openclaw

# Events (sorted by time)
kubectl get events -n openclaw --sort-by='.lastTimestamp'

# Describe pod for debugging
kubectl describe pod -l app.kubernetes.io/name=openclaw -n openclaw
```
