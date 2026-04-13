#!/usr/bin/env zsh
set -e

SCRIPT_DIR="${0:a:h}"
REGISTRY="oci.killinit.cc"
IMAGE="garage-webadmin"
BUILD_DIR="/tmp/garage-webadmin-build"
TAR_FILE="/tmp/garage-webadmin-amd64.tar"
BUILDER_NAME="garage-webadmin-builder"

echo "==> Cloning upstream..."
rm -rf "$BUILD_DIR"
git clone --depth=1 https://git.deuxfleurs.fr/Deuxfleurs/garage-webadmin.git "$BUILD_DIR"

echo "==> Applying overlay..."
cp "$SCRIPT_DIR/Dockerfile" "$BUILD_DIR/Dockerfile"
cp "$SCRIPT_DIR/nginx.conf.template" "$BUILD_DIR/nginx.conf.template"
cp -r "$SCRIPT_DIR/overlay" "$BUILD_DIR/overlay"

echo "==> Setting up buildx builder..."
docker buildx inspect "$BUILDER_NAME" &>/dev/null || docker buildx create --name "$BUILDER_NAME" --driver docker-container

echo "==> Building image (linux/amd64)..."
docker buildx build \
  --builder "$BUILDER_NAME" \
  --platform linux/amd64 \
  --output "type=docker,dest=$TAR_FILE" \
  --provenance=false \
  "$BUILD_DIR"

echo "==> Pushing to $REGISTRY (OCI format)..."
skopeo copy \
  --format oci \
  "docker-archive:$TAR_FILE" \
  "docker://$REGISTRY/$IMAGE:latest"

echo "==> Restarting deployment..."
kubectl --context admin@k8s.killinit.internal rollout restart deployment/garage-webui -n garage
kubectl --context admin@k8s.killinit.internal rollout status deployment/garage-webui -n garage

echo "==> Done. https://garage.killinit.cc/"
