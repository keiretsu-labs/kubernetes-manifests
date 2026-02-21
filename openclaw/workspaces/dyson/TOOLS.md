# Tools

All tools at `/usr/local/bin/`. Authenticated as `rajsinghtechbot` via GITHUB_TOKEN.

## kubectl (multi-context)

```bash
# Always specify context explicitly
kubectl --context talos-ottawa get pods -A
kubectl --context talos-robbinsdale get nodes -o wide
kubectl --context talos-stpetersburg get pods -n gpu-operator

# Quick cluster sweep
for ctx in talos-ottawa talos-robbinsdale talos-stpetersburg; do
  echo "=== $ctx ==="
  kubectl --context "$ctx" get nodes -o wide
done

# Pod failures
kubectl --context talos-ottawa get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Recent warnings
kubectl --context talos-ottawa get events -A --sort-by='.lastTimestamp' --field-selector type=Warning | tail -20

# Logs
kubectl --context talos-ottawa logs -n <ns> <pod> -c <container> --tail=50

# Resource usage
kubectl --context talos-ottawa top nodes
kubectl --context talos-ottawa top pods -A --sort-by=memory | head -20
```

## flux

```bash
# Kustomization status
flux --context talos-ottawa get kustomizations -A

# HelmRelease status
flux --context talos-ottawa get helmreleases -A

# Source status
flux --context talos-ottawa get sources git -A
flux --context talos-ottawa get sources helm -A

# Force reconcile (read-only safe — tells Flux to re-check, doesn't mutate)
flux --context talos-ottawa reconcile kustomization flux-system --with-source

# Suspend/resume (use sparingly, only for debugging)
flux --context talos-ottawa suspend kustomization <name>
flux --context talos-ottawa resume kustomization <name>
```

## gh

```bash
# Clone kubernetes-manifests
gh repo clone rajsinghtech/kubernetes-manifests -- /tmp/k8s-manifests

# Create PR
gh pr create --repo rajsinghtech/kubernetes-manifests \
  --title "fix(ottawa): description" \
  --body "## Problem\n...\n## Fix\n..."

# Check CI
gh run list --repo rajsinghtech/kubernetes-manifests --limit 5

# View open PRs
gh pr list --repo rajsinghtech/kubernetes-manifests
```

## helm (read-only)

```bash
# List releases
helm --kube-context talos-ottawa list -A

# Get current values
helm --kube-context talos-ottawa get values <release> -n <ns>

# Release status
helm --kube-context talos-ottawa status <release> -n <ns>

# Show chart info
helm --kube-context talos-ottawa get manifest <release> -n <ns> | head -50
```

## Rook-Ceph (Ottawa + Robbinsdale only)

```bash
# Ceph status via toolbox
kubectl --context talos-ottawa exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
kubectl --context talos-ottawa exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status
kubectl --context talos-ottawa exec -n rook-ceph deploy/rook-ceph-tools -- ceph df
kubectl --context talos-ottawa exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd pool ls detail
kubectl --context talos-ottawa exec -n rook-ceph deploy/rook-ceph-tools -- rados df

# PVC status
kubectl --context talos-ottawa get pvc -A | grep -v Bound
```

## Prometheus / Alertmanager

```bash
# Query firing alerts
kubectl --context talos-ottawa exec -n monitoring deploy/kube-prometheus-stack-prometheus -- \
  promtool query instant http://localhost:9090 'ALERTS{alertstate="firing"}'

# Alternatively via curl
kubectl --context talos-ottawa port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/alerts' | jq '.data.alerts[] | select(.state=="firing")'

# Alertmanager silences
kubectl --context talos-ottawa port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
curl -s 'http://localhost:9093/api/v2/alerts?active=true' | jq '.[].labels'
```

## Validation

```bash
# Kustomize build (dry-run)
kustomize build /tmp/k8s-manifests/apps/<app>/ > /dev/null

# YAML lint
yq . <file.yaml> > /dev/null

# JSON lint
jq . <file.json> > /dev/null
```
