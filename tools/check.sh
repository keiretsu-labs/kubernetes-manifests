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

run_capped() {
  local label="$1"; shift
  local out
  out="$(mktemp)"

  if "$@" >"$out" 2>&1; then
    rm -f "$out"
    return 0
  fi

  echo "=== $label FAILED ===" >&2
  # Render output is mostly successful objects. Surface failure context first,
  # then retain the summary tail, without flooding agent context.
  rg -n -C 2 '✗|⊘|[Ee]rror|[Ff]ailed|blocked by' "$out" | tail -35 >&2 || true
  echo "--- summary tail ---" >&2
  tail -15 "$out" >&2
  echo "(showing focused diagnostics from '$*')" >&2
  rm -f "$out"
  exit 1
}

if [ "$QUICK" = 1 ]; then
  # Quick syntax check: validate kustomize build on a representative sample
  for dir in kubernetes/apps/base/*/; do
    [ -d "$dir" ] || continue
    ns=$(basename "$dir")
    for app in "$dir"*/; do
      [ -d "$app" ] || continue
      run_capped "syntax: $app" kustomize build --enable-helm "$app"
    done
  done
  echo "ok (quick)"
  exit 0
fi

if [ -n "$TARGET" ]; then
  run_capped "render" make "test-$TARGET"
else
  run_capped "render" make test
fi

echo "ok"
