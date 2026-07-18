#!/usr/bin/env bash
# tools/refs.sh — list every Git-tracked file that references <name>, so a
# decommission (or "what points at X?") is one call instead of an ad-hoc
# find/grep sweep. Prints FILE PATHS only — never file contents or secret
# values — as a stable, unique list.
#
# Searches tracked files only (so .git and gitignored generated/session files
# are excluded); also excludes .kube and *.dec/*.decrypted/*.bak/*.tmp
# defensively. Exit 0 with paths on a match; exit 1 when no tracked path or
# file content matches. A no-match result does not cover live/external state.
#
# Usage:
#   tools/refs.sh <name>
#   tools/refs.sh infisical
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -ge 1 ] || { echo "usage: ${0##*/} <name>" >&2; exit 2; }
name="$1"
cd "$ROOT"

# Restrict to tracked files, drop credential/generated paths.
excludes=(
  ':(exclude).kube/**'
  ':(exclude).hermes/**'
  ':(exclude)**/*.dec'
  ':(exclude)**/*.decrypted'
  ':(exclude)**/*.bak'
  ':(exclude)**/*.tmp'
)

results="$(
  {
    # files whose *contents* mention the name (fixed string, case-insensitive)
    git grep -I -F -i -l -e "$name" -- . "${excludes[@]}" 2>/dev/null || true
    # files whose *path* mentions the name
    git ls-files -- . "${excludes[@]}" 2>/dev/null | grep -i -F -- "$name" || true
  } | sort -u
)"

[ -n "$results" ] || { echo "refs.sh: no tracked file references '$name'" >&2; exit 1; }
printf '%s\n' "$results"
