#!/bin/bash
set -e

# Configure Tailscale network flow log and audit log streaming to Garage S3
# Usage: ./configure-log-streaming.sh <oauth_client_id> <oauth_client_secret>
#
# Requires: the tailscale-logs bucket and key to already exist in Garage
# The S3 credentials are read from the Kubernetes secret created by the Garage operator

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAILNET="keiretsu.ts.net"
S3_URL="https://s3.keiretsu.top"
S3_BUCKET="tailscale-logs"
S3_REGION="garage"
COMPRESSION="zstd"
UPLOAD_PERIOD=5

# Get OAuth access token
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <oauth_client_id> <oauth_client_secret>" >&2
    exit 1
fi

ACCESS_TOKEN=$("$SCRIPT_DIR/get-access-token.sh" "$1" "$2")

# Get S3 credentials from Kubernetes secret
S3_ACCESS_KEY=$(kubectl --context ottawa-k8s-operator.keiretsu.ts.net get secret tailscale-logs-s3-auth -n flux-system -o jsonpath='{.data.TAILSCALE_LOGS_S3_ACCESS_KEY}' | base64 -d)
S3_SECRET_KEY=$(kubectl --context ottawa-k8s-operator.keiretsu.ts.net get secret tailscale-logs-s3-auth -n flux-system -o jsonpath='{.data.TAILSCALE_LOGS_S3_SECRET_KEY}' | base64 -d)

if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    echo "Error: Could not read S3 credentials from tailscale-logs-s3-auth secret" >&2
    exit 1
fi

configure_stream() {
    local log_type="$1"
    local prefix="$2"

    echo "Configuring $log_type log streaming..."
    RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X PUT \
        -u "$ACCESS_TOKEN:" \
        -H "Content-Type: application/json" \
        -d "{
            \"destinationType\": \"s3\",
            \"url\": \"$S3_URL\",
            \"s3Bucket\": \"$S3_BUCKET\",
            \"s3Region\": \"$S3_REGION\",
            \"s3KeyPrefix\": \"$prefix\",
            \"s3AuthenticationType\": \"accesskey\",
            \"s3AccessKeyId\": \"$S3_ACCESS_KEY\",
            \"s3SecretAccessKey\": \"$S3_SECRET_KEY\",
            \"compressionFormat\": \"$COMPRESSION\",
            \"uploadPeriodMinutes\": $UPLOAD_PERIOD
        }" \
        "https://api.tailscale.com/api/v2/tailnet/$TAILNET/logging/$log_type/stream")

    HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1 | cut -d: -f2)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "204" ]; then
        echo "  $log_type: configured"
    else
        echo "  $log_type: failed (HTTP $HTTP_STATUS)" >&2
        echo "  $BODY" >&2
        return 1
    fi
}

check_status() {
    local log_type="$1"
    echo "Status for $log_type:"
    curl -s -u "$ACCESS_TOKEN:" \
        "https://api.tailscale.com/api/v2/tailnet/$TAILNET/logging/$log_type/stream/status" | jq .
}

# Configure both streams
configure_stream "network" "network/"
configure_stream "configuration" "audit/"

echo ""
echo "Checking stream status..."
check_status "network"
check_status "configuration"
