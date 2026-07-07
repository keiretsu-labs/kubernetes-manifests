#!/usr/bin/env bash
# Build + push the woodpecker-mcp image with the [kuzu] extra (embedded graph DB).
# Target: ghcr.io/rajsinghtech/woodpecker-mcp-kuzu
# Ottawa cluster is amd64; build natively on amd64 or cross-build on arm64 dev box.
set -euo pipefail

REGISTRY="ghcr.io"
REPO="${REGISTRY}/rajsinghtech/woodpecker-mcp-kuzu"
VERSION="0.2.0"
CONTEXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --provenance=false --sbom=false: Zot registry rejects BuildKit manifest lists;
# plain manifests work. See bhaiya CLAUDE.md.
docker build \
  --platform linux/amd64 \
  --provenance=false \
  --sbom=false \
  -t "${REPO}:${VERSION}" \
  -t "${REPO}:latest" \
  "${CONTEXT_DIR}"

echo "Pushing ${REPO}:${VERSION} + ${REPO}:latest"
docker push "${REPO}:${VERSION}"
docker push "${REPO}:latest"

echo "Done: ${REPO}:${VERSION} (+ :latest)"
