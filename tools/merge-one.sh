#!/usr/bin/env bash
# Merge one non-deploying PR as the kman GitHub App, then compare Flux health.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KGH=${MERGE_ONE_TEST_KGH:-/workspace/.config/bhaiya/fleet/bin/kgh}
REPO=/repos/keiretsu-labs/kubernetes-manifests
PR='' BASELINE='' TIMEOUT=1800

usage() {
  echo "usage: $0 --pr NUMBER --baseline NEW_FILE [--timeout SECONDS]" >&2
  echo "The baseline file is created before the merge and must not already exist." >&2
}
die() { echo "merge-one: $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --pr|--baseline|--timeout)
      (($# >= 2)) || { usage; exit 2; }
      case "$1" in
        --pr) PR=$2 ;;
        --baseline) BASELINE=$2 ;;
        --timeout) TIMEOUT=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ $PR =~ ^[1-9][0-9]*$ && -n $BASELINE && $TIMEOUT =~ ^[1-9][0-9]*$ ]] || { usage; exit 2; }
[[ ! -e $BASELINE && ! -L $BASELINE ]] || die "baseline path already exists: $BASELINE"
command -v jq >/dev/null || die "jq is required"
[[ -x $KGH ]] || die "kman App API helper unavailable: $KGH"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

api() {
  local output=$1 method=$2 path=$3 body=${4:-}
  "$KGH" "$method" "$path" "$body" >"$output" || die "App API request failed: $method $path"
  jq -e '(type == "object" or type == "array") and (if type == "object" then (.message? == null or .merged? == true) else true end)' "$output" >/dev/null ||
    die "App API rejected $method $path: $(jq -r '.message // "invalid response"' "$output" 2>/dev/null || echo 'invalid response')"
}

check_pr() {
  api "$tmp/pr.json" GET "$REPO/pulls/$PR"
  jq -e --arg sha "${head:-}" --arg base "${base_sha:-}" '
    .state == "open" and .draft == false and .base.ref == "main" and
    .mergeable == true and .mergeable_state == "clean" and
    ($sha == "" or .head.sha == $sha) and
    ($base == "" or .base.sha == $base) and
    ((.title | test("held|wip|do not merge"; "i")) | not) and
    ([.labels[]?.name | test("held|wip|do not merge"; "i")] | any | not) and
    (.user.login | test("renovate"; "i") | not)
  ' "$tmp/pr.json" >/dev/null || die "PR #$PR is closed, draft, held, Renovate-authored, changed, or not cleanly mergeable"
  head=$(jq -r '.head.sha' "$tmp/pr.json")
  base_sha=$(jq -r '.base.sha' "$tmp/pr.json")
  [[ $head =~ ^[0-9a-f]{40}$ ]] || die "invalid PR head SHA"
  [[ $base_sha =~ ^[0-9a-f]{40}$ ]] || die "invalid PR base SHA"
}

check_paths() {
  local count
  count=$(jq -r '.changed_files' "$tmp/pr.json")
  [[ $count =~ ^[0-9]+$ && $count -gt 0 && $count -le 100 ]] || die "PR file count must be 1..100"
  api "$tmp/files.json" GET "$REPO/pulls/$PR/files?per_page=100"
  jq -e --argjson count "$count" '
    type == "array" and length == $count and all(.[];
      .status != "removed" and
      (.filename | test("^(tools/|docs/|\\.renovate/|README\\.md$|\\.github/renovate\\.json$)")) and
      ((.previous_filename // "") | test("^(|tools/|docs/|\\.renovate/|README\\.md$|\\.github/renovate\\.json$)"))
    )
  ' "$tmp/files.json" >/dev/null || die "PR changes a cluster-applied, held, removed, or unreviewed path"
}

check_green() {
  api "$tmp/checks.json" GET "$REPO/commits/$head/check-runs?per_page=100"
  api "$tmp/status.json" GET "$REPO/commits/$head/status"
  jq -e '
    .total_count > 0 and .total_count <= 100 and
    (.check_runs | length) == .total_count and
    all(.check_runs[]; .status == "completed" and .conclusion == "success")
  ' "$tmp/checks.json" >/dev/null || die "PR #$PR checks are absent, pending, or not all successful"
  jq -e '(.state == "success") or (.state == "pending" and (.statuses | length) == 0)' \
    "$tmp/status.json" >/dev/null || die "PR #$PR legacy statuses are pending or failed"
}

# The key set includes Flux Kustomizations and HelmReleases, across all sites.
# Missing/Unknown Ready conditions are unhealthy; status details remain in the
# live resource for diagnosis and do not affect set comparison.
snapshot() {
  local destination=$1 cluster
  : >"$destination"
  for cluster in ot rb sp; do
    "$ROOT/tools/kc.sh" "$cluster" --request-timeout=20s get \
      kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io \
      -A -o json >"$tmp/$cluster-resources.json" || die "cannot read Flux health in $cluster"
    jq -e '.items | type == "array" and length > 0' \
      "$tmp/$cluster-resources.json" >/dev/null || die "empty or invalid Flux health response in $cluster"
    jq -r --arg cluster "$cluster" '
      .items[] |
      select((([.status.conditions[]? | select(.type == "Ready") | .status] | last) // "Unknown") != "True") |
      [$cluster, .kind, .metadata.namespace, .metadata.name] | join("/")
    ' "$tmp/$cluster-resources.json" >>"$destination" || die "invalid Flux health response in $cluster"
  done
  sort -u -o "$destination" "$destination"
}

check_pr
check_paths
check_green
snapshot "$tmp/before"
cp "$tmp/before" "$BASELINE" || die "cannot write baseline: $BASELINE"
echo "merge-one: recorded $(wc -l <"$BASELINE") not-ready Flux resources in $BASELINE"

# Revalidate the PR and its exact head after the live baseline, before mutation.
check_pr
check_paths
check_green
api "$tmp/merge.json" PUT "$REPO/pulls/$PR/merge" \
  "$(jq -nc --arg sha "$head" '{sha:$sha,merge_method:"merge"}')"
jq -e '.merged == true and (.sha | test("^[0-9a-f]{40}$"))' "$tmp/merge.json" >/dev/null ||
  die "App did not merge PR #$PR; baseline: $BASELINE"
merged_sha=$(jq -r '.sha' "$tmp/merge.json")
echo "merge-one: merged PR #$PR at $merged_sha; waiting up to ${TIMEOUT}s total for Flux"
deadline=$((SECONDS + TIMEOUT))
remaining() {
  local left=$((deadline - SECONDS))
  ((left > 0)) || die "Flux did not finish within ${TIMEOUT}s; PR #$PR is merged; inspect clusters before another merge"
  echo "$left"
}

# kubectl wait is read-only and handles an in-progress/Unknown Ready condition:
# the gate is the observed Git revision, not a transient Ready status.
for cluster in ot rb sp; do
  wait_seconds=$(remaining)
  if ! "$ROOT/tools/kc.sh" "$cluster" --request-timeout=20s -n flux-system wait \
    gitrepository/kubernetes-manifests \
    "--for=jsonpath={.status.artifact.revision}=main@sha1:$merged_sha" \
    "--timeout=${wait_seconds}s" >/dev/null; then
    die "Flux source in $cluster did not observe $merged_sha within ${TIMEOUT}s; PR #$PR is merged; inspect cluster before another merge"
  fi
  wait_seconds=$(remaining)
  if ! "$ROOT/tools/kc.sh" "$cluster" --request-timeout=20s -n flux-system wait \
    kustomization/kubernetes-apps \
    "--for=jsonpath={.status.lastAttemptedRevision}=main@sha1:$merged_sha" \
    "--timeout=${wait_seconds}s" >/dev/null; then
    die "Flux root in $cluster did not attempt $merged_sha within ${TIMEOUT}s; PR #$PR is merged; inspect cluster before another merge"
  fi
  # Ready may briefly be Unknown while reconciliation runs. A failed wait is
  # reported through the before/after health diff below.
  wait_seconds=$(remaining)
  "$ROOT/tools/kc.sh" "$cluster" --request-timeout=20s -n flux-system wait \
    kustomization/kubernetes-apps --for=condition=Ready=True \
    "--timeout=${wait_seconds}s" >/dev/null || true
done

snapshot "$tmp/after"
new=$(comm -13 "$BASELINE" "$tmp/after")
if [[ -n $new ]]; then
  echo "merge-one: STOP: newly not-ready Flux resources after PR #$PR ($merged_sha):" >&2
  printf '%s\n' "$new" >&2
  echo "merge-one: no automatic revert; baseline: $BASELINE" >&2
  exit 1
fi
echo "merge-one: PR #$PR passed Flux health gate; no new not-ready resources"
