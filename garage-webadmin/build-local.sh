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

echo "==> Installing deps and type-checking..."
(builtin cd "$BUILD_DIR" && npm ci --silent)
cp "$BUILD_DIR/overlay/src/auto-login.ts" "$BUILD_DIR/src/auto-login.ts"
cp -r "$BUILD_DIR/overlay/src/pages/." "$BUILD_DIR/src/pages/"
(builtin cd "$BUILD_DIR" && npm run type-check)

echo "==> Setting up buildx builder..."
docker buildx inspect "$BUILDER_NAME" &>/dev/null || docker buildx create --name "$BUILDER_NAME" --driver docker-container

echo "==> Building image (linux/amd64)..."
docker buildx build \
  --builder "$BUILDER_NAME" \
  --platform linux/amd64 \
  --output "type=docker,dest=$TAR_FILE" \
  --provenance=false \
  --no-cache \
  "$BUILD_DIR"

echo "==> Pushing to $REGISTRY (OCI format)..."
skopeo copy \
  --format oci \
  "docker-archive:$TAR_FILE" \
  "docker://$REGISTRY/$IMAGE:latest"

echo "==> Building sidecar..."
SIDECAR_DIR="$SCRIPT_DIR/sidecar"
SIDECAR_TAR="/tmp/garage-webadmin-sidecar-amd64.tar"
docker buildx build \
  --builder "$BUILDER_NAME" \
  --platform linux/amd64 \
  --output "type=docker,dest=$SIDECAR_TAR" \
  --provenance=false \
  "$SIDECAR_DIR"

echo "==> Pushing sidecar to $REGISTRY (OCI format)..."
skopeo copy \
  --format oci \
  "docker-archive:$SIDECAR_TAR" \
  "docker://$REGISTRY/garage-webadmin-sidecar:latest"

echo "==> Restarting deployment..."
kubectl --context admin@k8s.killinit.internal rollout restart deployment/garage-webui -n garage
kubectl --context admin@k8s.killinit.internal rollout status deployment/garage-webui -n garage

echo "==> Done. https://garage.killinit.cc/"
