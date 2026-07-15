#!/usr/bin/env bash
# tools/clippy-all.sh — stub for Kustomize/Flux repo.
# In a Go or Rust repo this would run linters in one pass; here we just run
# kustomize validate + flate render-test on all clusters.
#
# Usage:
#   tools/clippy-all.sh              # full validation
#   tools/clippy-all.sh <cluster>    # single cluster
set -euo pipefail

TARGET=""
for a in "$@"; do
  case "$a" in
    --*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) TARGET="$a" ;;
  esac
done

echo "=== kustomize validation ===" >&2

# Validate all base apps can build with helm
for dir in kubernetes/apps/base/*/; do
  [ -d "$dir" ] || continue
  ns=$(basename "$dir")
  for app in "$dir"*/; do
    [ -d "$app" ] || continue
    out=$(kustomize build --enable-helm "$app" 2>&1) || {
      echo "FAIL: $app"
      echo "$out" | head -10
    }
  done
done

echo "=== render test ===" >&2
if [ -n "$TARGET" ]; then
  make "test-$TARGET" 2>&1 || echo "FAIL: render $TARGET"
else
  make test 2>&1 || echo "FAIL: render"
fi

echo "done"
