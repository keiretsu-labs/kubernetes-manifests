#!/usr/bin/env bash
# tools/where.sh — find line numbers of a pattern in a file without re-reading
# the whole file into an agent's context. Prints "file:line: matched-text" for
# each hit (like grep -n).
#
# Usage:
#   tools/where.sh <pattern> <file>            # case-insensitive grep -n
#   tools/where.sh <pattern> <file> [extra rg/grep flags]
# <file> is tried as given first, then relative to the repo root, so a
# repo-relative path resolves from any cwd.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -lt 2 ]; then
  echo "usage: $0 <pattern> <file> [grep flags...]" >&2
  exit 2
fi
PATTERN="$1"; FILE="$2"; shift 2

if [ ! -f "$FILE" ] && [ -f "$ROOT/$FILE" ]; then
  FILE="$ROOT/$FILE"
fi
if [ ! -f "$FILE" ]; then
  echo "$0: not a file: $FILE" >&2
  exit 1
fi

if command -v rg >/dev/null 2>&1; then
  rg -n -i --no-heading --color never "$@" "$PATTERN" "$FILE" || true
else
  grep -n -i --color=never "$@" "$PATTERN" "$FILE" || true
fi
