#!/usr/bin/env bash
# tools/check.sh — the kubernetes-manifests acceptance gate for kustomize/flux.
# Silent on success. On failure prints only the first ~50 lines of the failing
# step, so build agents don't dump full output into their context.
#
# Usage:
#   tools/check.sh                       # full gate (render-test all clusters)
#   tools/check.sh <cluster>             # single cluster, e.g. tools/check.sh talos-ottawa
#   tools/check.sh --quick               # quick check (just syntax, no full render)
set -euo pipefail

QUICK=0
TARGET=""
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    --*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) TARGET="$a" ;;
  esac
done

fail() {
  local label="$1"; shift
  echo "=== $label FAILED ===" >&2
  local out
  out="$("$@" 2>&1 || true)"
  printf '%s\n' "$out" | head -50 >&2
  echo "(run '$*' to see full output)" >&2
  exit 1
}

if [ "$QUICK" = 1 ]; then
  # Quick syntax check: validate kustomize build on a representative sample
  for dir in kubernetes/apps/base/*/; do
    [ -d "$dir" ] || continue
    ns=$(basename "$dir")
    for app in "$dir"*/; do
      [ -d "$app" ] || continue
      kustomize build --enable-helm "$app" >/dev/null 2>&1 || fail "syntax: $app" kustomize build --enable-helm "$app"
    done
  done
  echo "ok (quick)"
  exit 0
fi

if [ -n "$TARGET" ]; then
  make "test-$TARGET" >/dev/null 2>&1 || fail "render" make "test-$TARGET"
else
  make test >/dev/null 2>&1 || fail "render" make test
fi

echo "ok"
