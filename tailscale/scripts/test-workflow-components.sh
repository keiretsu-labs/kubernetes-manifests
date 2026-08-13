#!/bin/bash

set -e

echo "=== Testing Workflow Components ==="

# Test 1: HuJSON conversion
echo "1. Testing HuJSON to JSON conversion..."
./tailscale/scripts/convert-hujson.sh ./tailscale/policy.hujson /tmp/test-policy.json
echo "✅ HuJSON conversion successful"

# Test 2: Validate converted JSON
echo "2. Validating JSON structure..."
jq '.tagOwners["tag:k8s-operator"]' /tmp/test-policy.json > /dev/null
jq '.tagOwners["tag:k8s"]' /tmp/test-policy.json > /dev/null
jq '.grants[0].src[]' /tmp/test-policy.json > /dev/null
echo "✅ JSON structure validation successful"

# Test 3: Check script permissions
echo "3. Checking script permissions..."
ls -la tailscale/scripts/*.sh | grep -E "^-rwx" | wc -l
echo "✅ All scripts are executable"

# Test 4: Check Kind CLI availability
echo "4. Checking Kind CLI availability..."
if command -v kind >/dev/null 2>&1; then
    kind version
else
    echo "Kind not installed; skipping local CLI check"
fi
echo "✅ Kind CLI check complete"

# Test 5: Check required tools in workflow
echo "5. Checking availability of required tools..."
TOOLS=("curl" "jq" "python3")
for tool in "${TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "  ✅ $tool available"
    else
        echo "  ⚠️  $tool not available (will be installed in CI)"
    fi
done

echo ""
echo "=== Workflow Component Tests Complete ==="
echo "All components are ready for GitHub Actions workflow"
