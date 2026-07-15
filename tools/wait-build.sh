#!/usr/bin/env bash
# tools/wait-build.sh — block until a backgrounded process exits, then print
# only the final log tail + exit code.
#
# Usage:
#   tools/wait-build.sh <pid> <logfile> [timeout_sec]
# Exit status: the waited process's exit status (0 = success).
set -uo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <pid> <logfile> [timeout_sec]" >&2
  exit 2
fi
PID="$1"; LOG="$2"; TIMEOUT="${3:-300}"

ELAPSED=0
while kill -0 "$PID" 2>/dev/null; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "=== TIMEOUT after ${TIMEOUT}s (pid $PID still running) ===" >&2
    echo "--- last 30 log lines ---" >&2
    tail -30 "$LOG" 2>/dev/null >&2 || true
    exit 124
  fi
done

wait "$PID" 2>/dev/null
EXIT=$?

echo "=== pid $PID exited with status $EXIT after ~${ELAPSED}s ==="
echo "--- last 30 log lines ---"
tail -30 "$LOG" 2>/dev/null || true
exit "$EXIT"
