#!/usr/bin/env bash
# tools/check.sh — the kubernetes-manifests acceptance gate for kustomize/flux.
# Prints exactly one line on success; on failure prints only the first ~50 lines
# of the failing step, so build agents don't dump full output into their context.
# Anchored to the repo root, so it runs from any cwd.
#
# The full gate renders all three clusters concurrently. If only one cluster
# changed, scope it anyway: `tools/check.sh talos-ottawa`.
#
# Usage:
#   tools/check.sh                       # full gate (render-test all clusters)
#   tools/check.sh <cluster>             # single cluster, e.g. tools/check.sh talos-ottawa
#   tools/check.sh --quick               # quick check (just syntax, no full render)
set -euo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  tools/check.sh
  tools/check.sh <talos-ottawa|talos-robbinsdale|talos-stpetersburg>
  tools/check.sh --quick
EOF
}

QUICK=0
TARGET=""
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*) echo "unknown flag: $a" >&2; exit 2 ;;
    *)
      if [ -n "$TARGET" ]; then
        echo "error: expected at most one cluster target" >&2
        exit 2
      fi
      TARGET="$a"
      ;;
  esac
done

case "$TARGET" in
  "") ;;
  ot|ottawa|talos-ottawa) TARGET="talos-ottawa" ;;
  rb|robbinsdale|talos-robbinsdale) TARGET="talos-robbinsdale" ;;
  sp|stpetersburg|talos-stpetersburg) TARGET="talos-stpetersburg" ;;
  *)
    echo "error: unknown cluster '$TARGET' (valid: talos-ottawa, talos-robbinsdale, talos-stpetersburg)" >&2
    exit 2
    ;;
esac
if [ "$QUICK" = 1 ] && [ -n "$TARGET" ]; then
  echo "error: --quick does not accept a cluster target" >&2
  exit 2
fi

# Flate occasionally wedges in a CPU spin instead of returning, which hangs the
# gate forever. macOS ships no coreutils `timeout`, so enable job control to put
# the render in its own process group and kill the whole group on deadline —
# signalling `make` alone would orphan the spinning flate child.
CHECK_TIMEOUT="${KMAN_CHECK_TIMEOUT:-600}"

run_capped() {
  local label="$1"; shift
  local out timedout rc=0
  out="$(mktemp)"
  timedout="$(mktemp)"

  set -m
  "$@" >"$out" 2>&1 &
  local pid=$!
  set +m

  {
    sleep "$CHECK_TIMEOUT"
    printf 'yes' >"$timedout"
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 5
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
  } >/dev/null 2>&1 &
  local watchdog=$!

  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  if [ -s "$timedout" ]; then
    rm -f "$timedout"
    echo "=== $label TIMED OUT after ${CHECK_TIMEOUT}s ===" >&2
    echo "killed process group; raise the budget with KMAN_CHECK_TIMEOUT=<secs>" >&2
    tail -15 "$out" >&2
    rm -f "$out"
    exit 124
  fi
  rm -f "$timedout"

  if [ "$rc" -eq 0 ]; then
    rm -f "$out"
    return 0
  fi

  echo "=== $label FAILED ===" >&2
  # Render output is mostly successful objects. Surface failure context first,
  # then retain the summary tail, without flooding agent context.
  if command -v rg >/dev/null 2>&1; then
    rg -n -C 2 '✗|⊘|[Ee]rror|[Ff]ailed|blocked by' "$out" | tail -35 >&2 || true
  else
    grep -n -C 2 -E '✗|⊘|[Ee]rror|[Ff]ailed|blocked by' "$out" | tail -35 >&2 || true
  fi
  echo "--- summary tail ---" >&2
  tail -15 "$out" >&2
  echo "(showing focused diagnostics from '$*')" >&2
  rm -f "$out"
  exit 1
}

run_capped "version-sync" tools/check-versions.sh

if [ "$QUICK" = 1 ]; then
  # Quick syntax check: validate kustomize build on a representative sample
  for dir in kubernetes/apps/base/*/; do
    [ -d "$dir" ] || continue
    for app in "$dir"*/; do
      [ -d "$app" ] || continue
      run_capped "syntax: $app" kustomize build --enable-helm "$app"
    done
  done
  echo "✓ syntax OK"
  exit 0
fi

if [ -n "$TARGET" ]; then
  run_capped "render" make "test-$TARGET"
  echo "✓ render OK: $TARGET"
else
  run_capped "render" make test
  echo "✓ render OK: talos-ottawa talos-robbinsdale talos-stpetersburg"
fi
