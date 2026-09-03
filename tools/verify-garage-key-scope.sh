#!/usr/bin/env bash
# Verify the reconciled GarageKey scopes without changing cluster state.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly FLUX_NAMESPACE="flux-system"

die() {
  echo "error: $*" >&2
  exit 1
}

command -v jq >/dev/null || die "jq is required"

kube() {
  "$REPO_ROOT/tools/kc.sh" ot "$@"
}

check_flux_ready() {
  local name="$1"
  local ready
  ready="$(kube -n "$FLUX_NAMESPACE" get kustomization "$name" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  [[ "$ready" == "True" ]] || die "Flux $name Kustomization is not Ready: ${ready:-<missing>}"
  echo "  Flux $name: Ready=True"
}

check_no_cluster_wide_access() {
  local namespace="$1"
  local name="$2"
  local key_json="$3"
  jq -e '
    ((.spec.allBuckets // {}) | (.read // false) == false and (.write // false) == false and (.owner // false) == false) and
    (.status.clusterWide == false) and
    ([.spec.bucketPermissions // [] | .[]] | length == 0)
  ' <<<"$key_json" >/dev/null || \
    die "$namespace/$name still has effective cluster-wide or bucket permissions"
  echo "  $namespace/$name: no effective allBuckets or bucket permissions"
}

check_web_ui_scope() {
  local key_json="$1"
  local expected='[{"name":"bookorbit-postgres","owner":false,"read":true,"write":true},{"name":"immich-postgres","owner":false,"read":true,"write":true},{"name":"mimir","owner":false,"read":true,"write":true},{"name":"omnibus-postgres","owner":false,"read":true,"write":true},{"name":"tailscale-logs","owner":false,"read":true,"write":true},{"name":"tracearr-postgres","owner":false,"read":true,"write":true}]'
  local actual
  actual="$(jq -c '
    [.spec.bucketPermissions // [] | .[] |
      {name: .bucketRef.name, owner: (.owner // false), read: (.read // false), write: (.write // false)}]
    | sort_by(.name)
  ' <<<"$key_json")"
  [[ "$actual" == "$expected" ]] || die "web UI key scope differs from expected: $actual"
  jq -e '((.spec.allBuckets // {}) | (.read // false) == false and (.write // false) == false and (.owner // false) == false) and (.status.clusterWide == false)' \
    <<<"$key_json" >/dev/null || die "garage/webui-sidecar-key remains cluster-wide"
  echo "  garage/webui-sidecar-key: six explicit read/write scopes, owner=false"
}

echo "Checking read-only post-reconcile GarageKey state"
check_flux_ready garage-bucket
check_flux_ready hermes

web_key="$(kube -n garage get garagekey webui-sidecar-key -o json)"
hermes_key="$(kube -n hermes get garagekey hermes-s3-key -o json)"
check_web_ui_scope "$web_key"
check_no_cluster_wide_access hermes hermes-s3-key "$hermes_key"

echo "GarageKey scope verification passed without mutating Garage or Kubernetes."
