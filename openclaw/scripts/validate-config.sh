#!/bin/bash
# Validates openclaw.json for known misconfigurations.
# Usage: validate-config.sh [config-file]

CONFIG_FILE="${1:-kustomization/openclaw.json}"

[ -f "$CONFIG_FILE" ] || { echo "ERROR: not found: $CONFIG_FILE"; exit 1; }
command -v jq &>/dev/null || { echo "ERROR: jq required"; exit 1; }

echo "Validating $CONFIG_FILE..."
ERRORS=0

# gateway.bind=loopback/localhost: Kubernetes service traffic arrives on pod eth0, not loopback
bind=$(jq -r '.gateway.bind // empty' "$CONFIG_FILE")
if [ "$bind" = "loopback" ] || [ "$bind" = "localhost" ]; then
    echo "ERROR: gateway.bind=$bind — Kubernetes service traffic cannot reach loopback interface"
    echo "       Use gateway.bind=lan"
    ERRORS=$((ERRORS + 1))
fi

# gateway.bind=lan with auth.mode=none: OpenClaw refuses to start
if jq -e '.gateway.bind == "lan" and .gateway.auth.mode == "none"' "$CONFIG_FILE" > /dev/null 2>&1; then
    echo "ERROR: gateway.bind=lan with auth.mode=none is rejected by OpenClaw at startup"
    echo "       Set auth.mode=token with OPENCLAW_GATEWAY_TOKEN or token via Flux substitution"
    ERRORS=$((ERRORS + 1))
fi

# Flux postBuild escaping: ${VAR} gets consumed by Flux.
# Lines with ${VAR} not also containing $${VAR} are flagged as a warning.
# Intentional Flux substitutions (e.g. "${DEFAULT_PASSWORD}") will appear here — that is expected.
unescaped=$(grep -nE '\$\{[A-Z_][A-Z0-9_]*\}' "$CONFIG_FILE" | grep -vE '\$\$\{' || true)
if [ -n "$unescaped" ]; then
    echo "WARNING: Flux variable references found (will be substituted at deploy time):"
    echo "$unescaped" | head -5
    echo "         If intentional, ignore. If not, escape as \$\${VAR} to pass through literally."
fi

[ "$ERRORS" -eq 0 ] && echo "Validation passed." || { echo "$ERRORS error(s) found."; exit 1; }
