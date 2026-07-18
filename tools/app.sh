#!/usr/bin/env bash
# tools/app.sh — locate an app across base manifests and per-cluster overlays.
# Answers "where is <app> defined and which clusters deploy it?" in one shot,
# instead of fanning a find + cross-tree grep into agent context. Anchored to
# the script's own location, so it works from any cwd.
#
# Usage:
#   tools/app.sh <name>          # case-insensitive substring match
#   tools/app.sh --list          # full inventory: app | base path | clusters
#
# <name> matches base dirs (kubernetes/apps/base/<ns>/<app>*) by directory name
# and per-cluster pointer files (kubernetes/apps/<loc>/<ns>/<app>.yaml) by name.
# --list derives each row from the pointers' spec.path, so it reflects what is
# actually deployed and where; its first column is the base-path leaf, not the
# Flux Kustomization metadata.name.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APPS="$ROOT/kubernetes/apps"
LOCS="ottawa robbinsdale stpetersburg"

list_inventory() {
  {
    for loc in $LOCS; do
      d="$APPS/$loc"
      [ -d "$d" ] || continue
      # tag every pointer path: line with its cluster
      grep -rn --include='*.yaml' -E '^[[:space:]]*path:[[:space:]]*\.?/?kubernetes/apps/base/' "$d" 2>/dev/null \
        | sed "s|^|$loc\t|"
    done
  } | awk -F'\t' '
    {
      loc=$1
      line=$2
      # line is "file:lineno:  path: ./kubernetes/apps/base/..."; strip file:lineno:
      sub(/^[^:]*:[^:]*:/, "", line)
      sub(/^[[:space:]]*path:[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      sub(/^\.\//, "", line)
      bp=line
      m=split(bp, seg, "/")
      leaf=seg[m]
      if (leaf=="app" && m>1) leaf=seg[m-1]
      if (index(seen[bp], "|"loc"|")==0) { seen[bp]=seen[bp] "|"loc"|"; clusters[bp]=clusters[bp] (clusters[bp]==""?"":" ") loc }
      app[bp]=leaf
    }
    END { for (bp in app) printf "%-28s %-46s %s\n", app[bp], bp, clusters[bp] }
  ' | sort
}

if [ $# -ge 1 ] && [ "$1" = "--list" ]; then
  list_inventory
  exit 0
fi

[ $# -ge 1 ] || { echo "usage: ${0##*/} <app-name-substring> | --list" >&2; exit 2; }
q="$1"
found=0

base_hits=$(find "$APPS/base" -mindepth 2 -maxdepth 2 -type d -iname "*$q*" 2>/dev/null | sort || true)
if [ -n "$base_hits" ]; then
  found=1
  echo "base manifests:"
  printf '%s\n' "$base_hits" | sed 's/^/  /'
fi

for c in $LOCS; do
  hits=$(find "$APPS/$c" -type f -iname "*$q*.yaml" 2>/dev/null | sort || true)
  [ -n "$hits" ] || continue
  found=1
  echo "$c pointers:"
  printf '%s\n' "$hits" | sed 's/^/  /'
done

[ "$found" = 1 ] || { echo "no base dir or pointer matching '*$q*'" >&2; exit 1; }
