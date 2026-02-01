#!/usr/bin/env bash
# Karmada Member Cluster Registration Bootstrap Script
#
# This script registers member clusters with the Karmada control plane.
# It creates the necessary service accounts, secrets, and Cluster CRs.
#
# Prerequisites:
# - kubectl access to all member clusters via Tailscale k8s-operator
# - Access to the Ottawa cluster where Karmada is installed
#
# Usage:
#   ./bootstrap.sh [cluster-name]
#   ./bootstrap.sh          # Register all clusters
#   ./bootstrap.sh ottawa   # Register only Ottawa
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cluster definitions
declare -A CLUSTERS=(
  ["ottawa"]="ottawa-k8s-operator.keiretsu.ts.net"
  ["robbinsdale"]="robbinsdale-k8s-operator.keiretsu.ts.net"
  ["stpetersburg"]="stpetersburg-k8s-operator.keiretsu.ts.net"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get Karmada kubeconfig
get_karmada_kubeconfig() {
  log_info "Fetching Karmada kubeconfig..."
  
  KARMADA_CONFIG=$(mktemp)
  kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
    get secret -n karmada-system karmada-kubeconfig \
    -o jsonpath='{.data.kubeconfig}' | base64 -d > "$KARMADA_CONFIG"
  
  # The kubeconfig uses internal DNS, we need to port-forward
  log_info "Starting port-forward to Karmada API server..."
  kubectl --context=ottawa-k8s-operator.keiretsu.ts.net \
    -n karmada-system port-forward svc/karmada-apiserver 5443:5443 &
  PF_PID=$!
  sleep 2
  
  # Update kubeconfig to use localhost
  sed -i 's|server: https://karmada-apiserver.karmada-system.svc.cluster.local:5443|server: https://127.0.0.1:5443|' "$KARMADA_CONFIG"
  
  echo "$KARMADA_CONFIG"
}

# Setup RBAC on a member cluster
setup_member_rbac() {
  local cluster_name=$1
  local context=${CLUSTERS[$cluster_name]}
  
  log_info "Setting up RBAC on $cluster_name ($context)..."
  
  kubectl --context="$context" apply -f "$SCRIPT_DIR/member-cluster-rbac.yaml"
  
  # Wait for token secret to be populated
  log_info "Waiting for service account tokens..."
  for i in {1..30}; do
    TOKEN=$(kubectl --context="$context" get secret karmada-controller-token \
      -n karmada-cluster -o jsonpath='{.data.token}' 2>/dev/null || true)
    if [[ -n "$TOKEN" ]]; then
      break
    fi
    sleep 1
  done
  
  if [[ -z "$TOKEN" ]]; then
    log_error "Failed to get token for $cluster_name"
    return 1
  fi
  
  log_info "RBAC setup complete for $cluster_name"
}

# Create secrets in Karmada
create_karmada_secrets() {
  local cluster_name=$1
  local context=${CLUSTERS[$cluster_name]}
  local karmada_config=$2
  
  log_info "Creating Karmada secrets for $cluster_name..."
  
  # Get controller token
  CONTROLLER_TOKEN=$(kubectl --context="$context" get secret karmada-controller-token \
    -n karmada-cluster -o jsonpath='{.data.token}' | base64 -d)
  
  # Get impersonator token
  IMPERSONATOR_TOKEN=$(kubectl --context="$context" get secret karmada-impersonator-token \
    -n karmada-cluster -o jsonpath='{.data.token}' | base64 -d)
  
  # Get CA certificate from cluster
  CA_BUNDLE=$(kubectl --context="$context" get configmap kube-root-ca.crt \
    -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -w0)
  
  # Ensure namespace exists in Karmada
  kubectl --kubeconfig="$karmada_config" create namespace karmada-cluster 2>/dev/null || true
  
  # Create kubeconfig secret
  cat <<EOF | kubectl --kubeconfig="$karmada_config" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${cluster_name}-kubeconfig
  namespace: karmada-cluster
stringData:
  token: ${CONTROLLER_TOKEN}
  caBundle: |
$(kubectl --context="$context" get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' | sed 's/^/    /')
EOF

  # Create impersonator secret
  cat <<EOF | kubectl --kubeconfig="$karmada_config" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${cluster_name}-impersonator
  namespace: karmada-cluster
stringData:
  token: ${IMPERSONATOR_TOKEN}
  caBundle: |
$(kubectl --context="$context" get configmap kube-root-ca.crt -n kube-system -o jsonpath='{.data.ca\.crt}' | sed 's/^/    /')
EOF

  log_info "Secrets created for $cluster_name"
}

# Register cluster with Karmada
register_cluster() {
  local cluster_name=$1
  local karmada_config=$2
  
  log_info "Registering $cluster_name with Karmada..."
  
  kubectl --kubeconfig="$karmada_config" apply -f "$SCRIPT_DIR/cluster-${cluster_name}.yaml"
  
  log_info "Cluster $cluster_name registered"
}

# Verify cluster registration
verify_cluster() {
  local cluster_name=$1
  local karmada_config=$2
  
  log_info "Verifying $cluster_name registration..."
  
  for i in {1..60}; do
    STATUS=$(kubectl --kubeconfig="$karmada_config" get cluster "$cluster_name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    
    if [[ "$STATUS" == "True" ]]; then
      log_info "✓ Cluster $cluster_name is Ready"
      return 0
    fi
    
    log_info "Waiting for $cluster_name to become ready (attempt $i/60)..."
    sleep 5
  done
  
  log_warn "Cluster $cluster_name did not become ready within timeout"
  kubectl --kubeconfig="$karmada_config" describe cluster "$cluster_name"
  return 1
}

# Cleanup port-forward
cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" 2>/dev/null || true
  fi
  if [[ -n "${KARMADA_CONFIG:-}" && -f "${KARMADA_CONFIG:-}" ]]; then
    rm -f "$KARMADA_CONFIG"
  fi
}
trap cleanup EXIT

# Main
main() {
  local target_cluster="${1:-all}"
  
  log_info "Karmada Cluster Registration Bootstrap"
  log_info "======================================"
  
  # Get Karmada kubeconfig
  KARMADA_CONFIG=$(get_karmada_kubeconfig)
  export KARMADA_CONFIG
  
  # Verify Karmada access
  log_info "Verifying Karmada API access..."
  if ! kubectl --kubeconfig="$KARMADA_CONFIG" get clusters 2>/dev/null; then
    log_error "Cannot access Karmada API. Check port-forward and kubeconfig."
    exit 1
  fi
  
  # Determine which clusters to register
  if [[ "$target_cluster" == "all" ]]; then
    clusters=("ottawa" "robbinsdale" "stpetersburg")
  else
    clusters=("$target_cluster")
  fi
  
  # Register each cluster
  for cluster in "${clusters[@]}"; do
    log_info ""
    log_info "Processing cluster: $cluster"
    log_info "----------------------------"
    
    # Check if already registered
    if kubectl --kubeconfig="$KARMADA_CONFIG" get cluster "$cluster" &>/dev/null; then
      log_warn "Cluster $cluster already registered, updating..."
    fi
    
    setup_member_rbac "$cluster"
    create_karmada_secrets "$cluster" "$KARMADA_CONFIG"
    register_cluster "$cluster" "$KARMADA_CONFIG"
    verify_cluster "$cluster" "$KARMADA_CONFIG"
  done
  
  log_info ""
  log_info "======================================"
  log_info "Registration complete!"
  log_info ""
  log_info "Verify with:"
  log_info "  kubectl --kubeconfig=$KARMADA_CONFIG get clusters"
  log_info ""
}

main "$@"
