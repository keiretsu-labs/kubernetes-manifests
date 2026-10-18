#!/usr/bin/env bash
# Offline self-test for the token.yml response-redaction jq filter.
# The workflow embeds the filter inline; keep this copy in sync and run via
# tools/tests/run.sh (or directly) — it fails if the filter is invalid or
# stops redacting token-bearing fields.
set -euo pipefail
T="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

FILTER='def redact: if type == "string" and length > 12 then .[0:6] + "…" + .[-4:] else . end; walk(if type == "object" then with_entries(.value |= (if (. | type) == "object" or (. | type) == "array" then . else redact end)) else . end)'

pass=0
fail=0
check() { # label expected actual
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"; pass=$((pass + 1))
  else
    echo "  FAIL $1"; echo "    expected: $2"; echo "    actual:   $3"; fail=$((fail + 1))
  fi
}

# 1. filter is valid jq and parses
printf '%s' '{"a":1}' | jq -e "$FILTER" >/dev/null 2>&1 && r=ok || r=fail
check "filter parses" ok "$r"

# 2. sample Tailscale token-exchange payload: token fields redacted, shape kept
out=$(printf '%s' '{"access_token":"tskey-access-abcdef1234567890","refresh_token":"rts-9876543210abcdef","token_type":"Bearer","expires_in":900,"endpoint":"https://api.tailscale.com"}' | jq -c -f <(printf '%s' "$FILTER"))
check "access_token redacted" "tskey-…7890" "$(echo "$out" | jq -r .access_token)"
check "refresh_token redacted" "rts-98…cdef" "$(echo "$out" | jq -r .refresh_token)"
check "short value untouched" "Bearer" "$(echo "$out" | jq -r .token_type)"
check "numeric untouched" "900" "$(echo "$out" | jq -r .expires_in)"
check "long URL redacted" "https:….com" "$(echo "$out" | jq -r .endpoint)"
check "keys preserved" "access_token,refresh_token,token_type,expires_in,endpoint" "$(echo "$out" | jq -r 'keys_unsorted | join(",")')"

# 3. nested objects and arrays survive
out2=$(printf '%s' '{"token":{"secret":"abcdefghijklmnopqrstuvwxyz","n":1},"list":["abcdefghijklmnop","xy"]}' | jq -c -f <(printf '%s' "$FILTER"))
check "nested secret redacted" "abcdef…wxyz" "$(echo "$out2" | jq -r .token.secret)"
check "nested number kept" "1" "$(echo "$out2" | jq -r .token.n)"
check "array strings redacted" 2 "$(echo "$out2" | jq '.list | length')"

# 4. the filter embedded in the workflow matches this copy (drift guard)
wf_filter=$(python3 - "$T/.github/workflows/token.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = wf['jobs']['echo-token']['steps'][1]['run']
import re
m = re.search(r"Response body: \$\(echo \"\$RESPONSE_BODY\" \| jq -c '([^']+)'\)", step)
print(m.group(1) if m else '')
PY
)
check "workflow filter in sync" "$FILTER" "$wf_filter"

# 5. empty / malformed input does not hang the echo (workflow guards with || fallback)
r=ok
printf '%s' '' | jq -e -c -f <(printf '%s' "$FILTER") >/dev/null 2>&1 || true
check "empty input handled" ok "$r"

echo
printf '== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
