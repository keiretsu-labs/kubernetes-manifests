#!/usr/bin/env bash
# tools/app.sh — locate an app across base manifests and per-cluster overlays.
# Answers "where is <app> defined and which clusters deploy it?" in one shot,
# instead of fanning a find + cross-tree grep into agent context.
#
# Usage:
#   tools/app.sh <name>          # case-insensitive substring match
# Matches base dirs (kubernetes/apps/base/<ns>/<app>*) by directory name and
# per-cluster pointer files (kubernetes/apps/<loc>/<ns>/<app>.yaml) by filename.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <app-name-substring>" >&2; exit 2; }
q="$1"
root="kubernetes/apps"
found=0

base_hits=$(find "$root/base" -mindepth 2 -maxdepth 2 -type d -iname "*$q*" 2>/dev/null | sort || true)
if [ -n "$base_hits" ]; then
  found=1
  echo "base manifests:"
  printf '  %s\n' $base_hits
fi

for c in ottawa robbinsdale stpetersburg; do
  hits=$(find "$root/$c" -type f -iname "*$q*.yaml" 2>/dev/null | sort || true)
  [ -n "$hits" ] || continue
  found=1
  echo "$c pointers:"
  printf '  %s\n' $hits
done

[ "$found" = 1 ] || { echo "no base dir or pointer matching '*$q*'" >&2; exit 1; }
