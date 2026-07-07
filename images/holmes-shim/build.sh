#!/usr/bin/env bash
set -euo pipefail

IMAGE="ghcr.io/rajsinghtech/holmes-shim"
TAG="0.1.0"

docker build --platform linux/amd64 --provenance=false --sbom=false \
  -t "${IMAGE}:${TAG}" \
  -t "${IMAGE}:latest" \
  .

docker push "${IMAGE}:${TAG}"
docker push "${IMAGE}:latest"

echo "Pushed ${IMAGE}:${TAG} and ${IMAGE}:latest"
