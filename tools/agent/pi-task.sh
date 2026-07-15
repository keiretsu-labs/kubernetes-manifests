#!/usr/bin/env bash
# pi-task.sh — unattended build-agent runs via pi (aperture/deepseek-v4-flash).
#
# pi -p is synchronous and exits on its own, so this stays thin: sensible
# defaults for the aperture backend, a portable watchdog (macOS has no
# `timeout` — we use perl's alarm), automatic retry on aperture's transient
# "503 no healthy upstream", and it prints the saved session path so the
# orchestrator can mine the transcript for wasted tool calls.
#
# The `aperture` pi provider lives in ~/.pi/agent/models.json (openai-completions,
# baseUrl http://aperture/v1). See docs/toolsmith.md for the analysis workflow.
#
# Usage:
#   tools/agent/pi-task.sh "<title>" "<self-contained prompt>" [deadline_secs=1800]
#   tools/agent/pi-task.sh --continue "<prompt>" [deadline_secs]   # continue last session
#
# Env: PI_PROVIDER=aperture  PI_MODEL=deepseek-v4-flash  PI_THINKING=off
#      PI_TOOLS=read,bash,edit,write,grep,find,ls  PI_RETRIES=3
#
# Run with Bash run_in_background:true; final assistant text lands on stdout.
# Exit: 0 ok; 124 watchdog timeout; 1 error / retries exhausted.
set -uo pipefail

PROVIDER="${PI_PROVIDER:-aperture}"
MODEL="${PI_MODEL:-deepseek-v4-flash}"
TOOLS="${PI_TOOLS:-read,bash,edit,write,grep,find,ls}"
THINKING="${PI_THINKING:-off}"
RETRIES="${PI_RETRIES:-3}"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"

command -v pi   >/dev/null 2>&1 || { echo "[pi-task] pi not in PATH" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "[pi-task] perl required for the watchdog" >&2; exit 1; }

ARGS=(-p -a --provider "$PROVIDER" --model "$MODEL" --thinking "$THINKING" -t "$TOOLS")
if [[ "${1:-}" == "--continue" ]]; then
  shift
  PROMPT="${1:?prompt text required}"; DEADLINE="${2:-1800}"; TITLE="continue"
  ARGS+=(-c)
else
  TITLE="${1:?usage: $0 <title> <prompt> [deadline_secs]  (or --continue <prompt>)}"
  PROMPT="${2:?prompt text required}"; DEADLINE="${3:-1800}"
  ARGS+=(-n "$TITLE")
fi

OUT="$(mktemp)"; ERR="$(mktemp)"; MARK="$(mktemp)"
trap 'rm -f "$OUT" "$ERR" "$MARK"' EXIT

attempt=1; rc=1
while [ "$attempt" -le "$RETRIES" ]; do
  echo "[pi-task] $TITLE attempt $attempt/$RETRIES (model=$PROVIDER/$MODEL deadline=${DEADLINE}s)" >&2
  ( cd "$DIR" && perl -e 'alarm shift; exec @ARGV' "$DEADLINE" pi "${ARGS[@]}" "$PROMPT" ) >"$OUT" 2>"$ERR"
  rc=$?
  if [ "$rc" -eq 142 ]; then echo "[pi-task] DEADLINE ${DEADLINE}s exceeded — killed" >&2; rc=124; break; fi
  if [ "$rc" -eq 0 ] && [ -s "$OUT" ]; then break; fi
  if grep -qiE '503|502|no healthy upstream|connection refused|ECONNREF|unexpected EOF|network error' "$ERR"; then
    echo "[pi-task] transient backend error (attempt $attempt):" >&2; tail -3 "$ERR" >&2
    attempt=$((attempt + 1)); sleep $((attempt * 5)); continue
  fi
  break
done

cat "$OUT"
SESS="$(find "$HOME/.pi/agent/sessions" -name '*.jsonl' -newer "$MARK" 2>/dev/null | sort | tail -1)"
[ -n "$SESS" ] && echo "[pi-task] session: $SESS" >&2
if [ "$rc" -ne 0 ]; then
  echo "[pi-task] FAILED rc=$rc after $attempt attempt(s)" >&2
  [ -s "$ERR" ] && { echo "--- stderr tail ---" >&2; tail -8 "$ERR" >&2; }
fi
exit "$rc"
