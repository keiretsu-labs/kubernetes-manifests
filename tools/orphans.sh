#!/usr/bin/env bash
# tools/orphans.sh — kustomization <-> disk drift detector for kubernetes/apps.
# Reports two discrepancy classes, prints nothing else:
#   MISSING   a resources/components/crds/bases/patch entry points at a local
#             target that does not exist (would break the render)
#   UNLISTED  a YAML file sits next to a kustomization.yaml that never names it
#             (plausibly dead / left behind by a decommission)
# Remote URLs (http, git::, oci, github.com, ?ref=) and generated files
# (*.dec, *.bak, *.tmp) are ignored to avoid false positives.
#
# Exit 0 = clean, 1 = discrepancies found, 2 = bad usage.
#
# Usage:
#   tools/orphans.sh            # scan kubernetes/apps
#   tools/orphans.sh <dir>      # scan an arbitrary tree (used by tests)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="${1:-$ROOT/kubernetes/apps}"
[ -d "$SCAN" ] || { echo "orphans.sh: not a directory: $SCAN" >&2; exit 2; }

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

is_remote() {
  case "$1" in
    *://*|github.com/*|gitlab.com/*|git@*|*'?ref='*) return 0 ;;
    *) return 1 ;;
  esac
}

# Pull resource-ish list entries and patch paths out of a kustomization.yaml.
entries() {
  awk '
    /^[A-Za-z].*:/ {
      key=$0; sub(/:.*/,"",key)
      mode=(key=="resources"||key=="components"||key=="crds"||key=="bases")?"r":((key=="patches")?"p":"")
      next
    }
    {
      v=""; ptype=""
      if (mode=="r" && $0 ~ /^[[:space:]]+-[[:space:]]/)      { v=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",v); ptype="r" }
      else if (mode=="p" && $0 ~ /path:[[:space:]]/)          { v=$0; sub(/^.*path:[[:space:]]*/,"",v); ptype="p" }
      if (v!="") {
        sub(/[[:space:]]*#.*/,"",v); sub(/[[:space:]]+$/,"",v); gsub(/"/,"",v)
        # patch entries: only .yaml/.yml file refs (skip inline JSON6902 path: /..., hostPaths)
        if (v!="" && (ptype=="r" || v ~ /\.ya?ml$/)) print v
      }
    }
  ' "$1"
}

while IFS= read -r kfile; do
  kdir=$(dirname "$kfile")

  # check 1: listed-but-missing local targets
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    is_remote "$entry" && continue
    [ -e "$kdir/$entry" ] || printf 'MISSING   %s  ->  %s\n' "${kfile#"$ROOT"/}" "$entry" >>"$report"
  done < <(entries "$kfile")

  # check 2: sibling YAML absent from this kustomization and from a direct
  # parent reference (some overlays hoist child/file.yaml one level up).
  for f in "$kdir"/*.yaml "$kdir"/*.yml; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = kustomization.yaml ] && continue
    case "$b" in *.dec|*.dec.yaml|*.bak|*.tmp) continue ;; esac
    grep -qF -- "$b" "$kfile" && continue
    parent="$(dirname "$kdir")/kustomization.yaml"
    rel="$(basename "$kdir")/$b"
    [ -f "$parent" ] && grep -qF -- "$rel" "$parent" && continue
    printf 'UNLISTED  %s\n' "${f#"$ROOT"/}" >>"$report"
  done
done < <(find "$SCAN" -type f -name kustomization.yaml)

if [ -s "$report" ]; then
  sort "$report"
  exit 1
fi
exit 0
