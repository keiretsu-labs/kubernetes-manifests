#!/usr/bin/env bash
# opencode-task.sh — unattended opencode orchestration via the server HTTP API.
#
# `opencode run` is synchronous with no timeout: when the model stalls the call
# blocks forever and the caller leaks a zombie process. This harness uses the
# persistent server instead: async prompt admission (204), allow-all permission
# ruleset at session create (replaces --auto), a hard watchdog deadline with
# abort, and result harvesting.
#
# Usage:
#   tools/agent/opencode-task.sh "<title>" "<prompt text>" [deadline_seconds]
#   tools/agent/opencode-task.sh --continue <sessionID> "<prompt text>" [deadline_seconds]
#
# Env: OPENCODE_URL   (default http://127.0.0.1:4096)
#      OPENCODE_MODEL (default neuralwatt/glm-5.2), OPENCODE_PROVIDER (ai)
#
# Exit: 0 completed; 3 watchdog abort (prints sessionID for --continue); 1 error.
set -euo pipefail

URL="${OPENCODE_URL:-http://127.0.0.1:4096}"
PROVIDER="${OPENCODE_PROVIDER:-ai}"
MODEL="${OPENCODE_MODEL:-aperture/deepseek-v4-flash}"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"

CONTINUE=""
if [[ "${1:-}" == "--continue" ]]; then
  CONTINUE="${2:?--continue requires a session ID}"; shift 2
  TITLE="$CONTINUE"
  PROMPT="${1:?prompt text}"
  DEADLINE="${2:-2400}"
else
  TITLE="${1:?title}"
  PROMPT="${2:?prompt text}"
  DEADLINE="${3:-2400}"   # 40 min default
fi

# 0. Ensure server is up.
if ! curl -sf --max-time 3 "$URL/api/health" >/dev/null 2>&1; then
  echo "[harness] starting opencode server at $URL" >&2
  nohup opencode serve --hostname 127.0.0.1 --port "${URL##*:}" >/tmp/opencode-serve.log 2>&1 &
  for _ in $(seq 1 20); do sleep 1; curl -sf --max-time 2 "$URL/api/health" >/dev/null 2>&1 && break; done || true
  curl -sf --max-time 3 "$URL/api/health" >/dev/null 2>&1 \
    || { echo "[harness] opencode server did not come up at $URL (see /tmp/opencode-serve.log)" >&2; exit 1; }
fi

# 1. Create session (allow-all permissions = unattended) or reuse.
if [[ -n "$CONTINUE" ]]; then
  SID="$CONTINUE"
  echo "[harness] continuing session $SID" >&2
else
  SID=$(curl -sfS -X POST "$URL/session?directory=$DIR" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "$TITLE" \
      '{title:$t, permission:[{permission:"*",pattern:"*",action:"allow"}]}')" | jq -r .id)
  [[ "$SID" == ses_* ]] || { echo "[harness] session create failed" >&2; exit 1; }
  echo "[harness] session $SID ($TITLE)" >&2
fi

# 2. Async prompt admission — returns 204 immediately.
curl -sfS --max-time 10 -o /dev/null -X POST "$URL/session/$SID/prompt_async?directory=$DIR" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg pid "$PROVIDER" --arg mid "$MODEL" --arg t "$PROMPT" \
    '{model:{providerID:$pid,modelID:$mid},parts:[{type:"text",text:$t}]}')" \
  || { echo "[harness] prompt admission failed for session $SID" >&2; exit 1; }
echo "[harness] prompt admitted; watchdog ${DEADLINE}s" >&2

msg_count() {
  curl -s --max-time 5 "$URL/session/$SID/message?directory=$DIR" | jq 'length' 2>/dev/null || echo 0
}
is_busy() {
  curl -s --max-time 5 "$URL/session/status" | jq -e --arg s "$SID" 'has($s)' >/dev/null 2>&1 && echo 1 || echo 0
}

# 3. Watchdog loop.
START=$(date +%s); LAST=0; IDLE=0
while :; do
  sleep 15
  ELAPSED=$(( $(date +%s) - START ))
  BUSY=$(is_busy); COUNT=$(msg_count)
  if [[ "$COUNT" != "$LAST" ]]; then
    echo "[harness] t=${ELAPSED}s messages=$COUNT busy=$BUSY" >&2
    LAST="$COUNT"; IDLE=0
  fi
  if [[ "$BUSY" == "0" ]]; then
    IDLE=$((IDLE+1)); [[ $IDLE -ge 2 ]] && break
  else
    IDLE=0
  fi
  if (( ELAPSED > DEADLINE )); then
    echo "[harness] DEADLINE ${DEADLINE}s exceeded — aborting session" >&2
    curl -sS --max-time 5 -o /dev/null -X POST "$URL/session/$SID/abort?directory=$DIR" || true
    echo "$SID"
    exit 3
  fi
done

# 4. Harvest final assistant text.
echo "[harness] done in $(( $(date +%s) - START ))s; session $SID" >&2
curl -s --max-time 10 "$URL/session/$SID/message?directory=$DIR" | jq -r '
  [.[] | select(.info.role=="assistant")] | last
  | if . == null then "(no assistant message produced — session may have aborted)"
    else [.parts[]? | select(.type=="text") | .text] | join("\n") end'
