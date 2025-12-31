#!/bin/bash
set -euo pipefail

# Bootstrap script for GKE uscentral1 cluster
# This script installs Cilium CNI and bootstraps Flux CD

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/uscentral1}"
CLUSTER_DIR="${REPO_ROOT}/clusters/gke-uscentral1"
COMMON_DIR="${REPO_ROOT}/clusters/common"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    command -v kubectl >/dev/null 2>&1 || error "kubectl is required"
    command -v helm >/dev/null 2>&1 || error "helm is required"
    command -v gcloud >/dev/null 2>&1 || error "gcloud is required"

    if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
        warn "Kubeconfig not found at ${KUBECONFIG_PATH}"
        log "Run: gcloud container clusters get-credentials gke-uscentral1 --region us-central1 --project YOUR_PROJECT"
        log "Then: cp ~/.kube/config ${KUBECONFIG_PATH}"
        exit 1
    fi
}

# Wait for nodes to be ready
wait_for_nodes() {
    log "Waiting for nodes to be ready..."
    kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready nodes --all --timeout=300s
}

# Install Cilium CNI
install_cilium() {
    log "Adding Cilium Helm repository..."
    helm repo add cilium https://helm.cilium.io/ || true
    helm repo update

    log "Installing Cilium..."
    # Check if cilium values exist for this cluster
    CILIUM_VALUES=""
    if [[ -f "${CLUSTER_DIR}/apps/cilium/app/values.yaml" ]]; then
        CILIUM_VALUES="-f ${CLUSTER_DIR}/apps/cilium/app/values.yaml"
    elif [[ -f "${COMMON_DIR}/apps/cilium/app/values.yaml" ]]; then
        CILIUM_VALUES="-f ${COMMON_DIR}/apps/cilium/app/values.yaml"
    fi

    helm upgrade --install cilium cilium/cilium \
        --version 1.18.3 \
        --namespace kube-system \
        --kubeconfig "${KUBECONFIG_PATH}" \
        --set operator.replicas=1 \
        --set ipam.mode=kubernetes \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost="${K8S_SERVICE_HOST:-}" \
        --set k8sServicePort="${K8S_SERVICE_PORT:-443}" \
        --set hubble.enabled=true \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true \
        ${CILIUM_VALUES}

    log "Waiting for Cilium to be ready..."
    kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system rollout status daemonset/cilium --timeout=300s
}

# Bootstrap Flux
bootstrap_flux() {
    log "Bootstrapping Flux..."

    # Apply Flux components and SOPS secret
    log "Applying Flux bootstrap manifests..."
    kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -k "${COMMON_DIR}/bootstrap/flux"

    # Wait for Flux CRDs to be established
    log "Waiting for Flux CRDs..."
    sleep 10
    kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for condition=established --timeout=60s crd/kustomizations.kustomize.toolkit.fluxcd.io || true
    kubectl --kubeconfig "${KUBECONFIG_PATH}" wait --for condition=established --timeout=60s crd/gitrepositories.source.toolkit.fluxcd.io || true

    # Apply cluster-specific Flux configuration
    log "Applying cluster Flux configuration..."
    kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -k "${CLUSTER_DIR}/flux/config"

    log "Flux bootstrap complete!"
}

# Verify installation
verify() {
    log "Verifying installation..."

    echo ""
    log "Nodes:"
    kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes

    echo ""
    log "Cilium status:"
    kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system get pods -l app.kubernetes.io/part-of=cilium

    echo ""
    log "Flux status:"
    kubectl --kubeconfig "${KUBECONFIG_PATH}" -n flux-system get pods

    echo ""
    log "GitRepository status:"
    kubectl --kubeconfig "${KUBECONFIG_PATH}" -n flux-system get gitrepositories

    echo ""
    log "Kustomizations:"
    kubectl --kubeconfig "${KUBECONFIG_PATH}" -n flux-system get kustomizations
}

main() {
    log "Starting GKE uscentral1 cluster bootstrap..."
    log "Using kubeconfig: ${KUBECONFIG_PATH}"

    check_prerequisites
    wait_for_nodes
    install_cilium
    bootstrap_flux
    verify

    echo ""
    log "Bootstrap complete! Flux will now reconcile the cluster state from Git."
    log "Monitor progress with: flux get all -A --kubeconfig ${KUBECONFIG_PATH}"
}

main "$@"
