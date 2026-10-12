#!/usr/bin/env bash
# Read-only gate for the OCI Flux owner overlap. Run after both new objects
# reconcile, before disabling pruning or suspending bhaiya-v2.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

get_flux() {
  "$ROOT/tools/kc.sh" ot -n flux-system get "$1" "$2" -o json > "$WORK/$3.json"
}

ready_at_current_generation() {
  jq -e '. as $object | (.status.observedGeneration == .metadata.generation) and
    ([.status.conditions[]? | select(.type == "Ready" and .status == "True" and
      .observedGeneration == $object.metadata.generation)] | length == 1)' "$WORK/$1.json" > /dev/null
}

inventory() {
  jq -er '.status.inventory.entries[] | [.id, .v] | @tsv' "$WORK/$1.json" | LC_ALL=C sort -u > "$WORK/$1.inventory"
  test -s "$WORK/$1.inventory"
}

get_flux ocirepositories.source.toolkit.fluxcd.io bhaiya-v2-deploy old-source
get_flux ocirepositories.source.toolkit.fluxcd.io bhaiya-deploy new-source
get_flux kustomizations.kustomize.toolkit.fluxcd.io bhaiya-v2 old-runtime
get_flux kustomizations.kustomize.toolkit.fluxcd.io bhaiya-runtime new-runtime
get_flux kustomizations.kustomize.toolkit.fluxcd.io bhaiya git-activation

for object in old-source new-source old-runtime new-runtime git-activation; do
  if ! ready_at_current_generation "$object"; then
    echo "FAIL: $object is not Ready at its current generation" >&2
    exit 1
  fi
done

if ! jq -e '.spec.prune == true and .spec.sourceRef.name == "bhaiya-v2-deploy"' "$WORK/old-runtime.json" > /dev/null ||
   ! jq -e '.spec.prune == false and .spec.deletionPolicy == "Orphan" and (.spec.suspend != true) and .spec.sourceRef.name == "bhaiya-deploy"' "$WORK/new-runtime.json" > /dev/null; then
  echo 'FAIL: runtime owner pruning or source reference differs from the handoff stage' >&2
  exit 1
fi

for field in .status.artifact.revision .status.artifact.digest; do
  old="$(jq -er "$field // empty" "$WORK/old-source.json")"
  new="$(jq -er "$field // empty" "$WORK/new-source.json")"
  if [[ "$old" != "$new" ]]; then
    echo "FAIL: source $field differs: old=$old new=$new" >&2
    exit 1
  fi
done

old_revision="$(jq -er '.status.lastAppliedRevision // empty' "$WORK/old-runtime.json")"
new_revision="$(jq -er '.status.lastAppliedRevision // empty' "$WORK/new-runtime.json")"
source_revision="$(jq -er '.status.artifact.revision // empty' "$WORK/new-source.json")"
if [[ "$old_revision" != "$new_revision" || "$new_revision" != "$source_revision" ]]; then
  echo "FAIL: applied revisions differ: old=$old_revision new=$new_revision source=$source_revision" >&2
  exit 1
fi

old_spec="$(jq -Sc '.spec | del(.sourceRef.name, .prune, .deletionPolicy, .suspend)' "$WORK/old-runtime.json")"
new_spec="$(jq -Sc '.spec | del(.sourceRef.name, .prune, .deletionPolicy, .suspend)' "$WORK/new-runtime.json")"
if [[ "$old_spec" != "$new_spec" ]] ||
   [[ "$(jq -Sc '.metadata.labels' "$WORK/old-runtime.json")" != "$(jq -Sc '.metadata.labels' "$WORK/new-runtime.json")" ]]; then
  echo 'FAIL: runtime spec or labels differ beyond the planned handoff fields' >&2
  exit 1
fi

inventory old-runtime
inventory new-runtime
inventory git-activation
comm -3 "$WORK/old-runtime.inventory" "$WORK/new-runtime.inventory" > "$WORK/inventory-difference"
if [[ -s "$WORK/inventory-difference" ]]; then
  cat "$WORK/inventory-difference" >&2
  echo 'FAIL: replacement inventory is not the complete old inventory set' >&2
  exit 1
fi

comm -12 "$WORK/new-runtime.inventory" "$WORK/git-activation.inventory" > "$WORK/overlap"
if [[ -s "$WORK/overlap" ]]; then
  echo 'FAIL: runtime and Git activation inventories overlap:' >&2
  cat "$WORK/overlap" >&2
  exit 1
fi

echo "PASS: OCI revision $new_revision"
echo "PASS: OCI digest $(jq -r '.status.artifact.digest' "$WORK/new-source.json")"
echo "PASS: runtime inventory adopted: $(wc -l < "$WORK/new-runtime.inventory") identical entries; no Git activation overlap"
echo 'PASS: both runtime owners Ready at current generation with matching spec and labels; replacement pruning disabled'
echo 'NEXT: inspect live object UIDs and prune events before a separate commit disarms the old owner'
