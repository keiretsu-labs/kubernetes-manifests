#!/usr/bin/env bash
set -e

echo "[laptop-init] Configuring git..."
git config --global user.name "rajsinghtechbot"
git config --global user.email "king360raj@gmail.com"
git config --global credential.https://github.com.helper \
  '!f() { echo "username=x-access-token"; echo "password=$GITHUB_TOKEN"; }; f'

echo "[laptop-init] Setting up workspace..."
mkdir -p /workspace
if [ ! -d /workspace/kubernetes-manifests/.git ]; then
  echo "[laptop-init] Cloning kubernetes-manifests..."
  git clone https://github.com/rajsinghtech/kubernetes-manifests.git /workspace/kubernetes-manifests
else
  echo "[laptop-init] kubernetes-manifests already cloned, skipping"
fi

echo "[laptop-init] Configuring shell..."
echo 'export KUBECONFIG=/config/.kube/config' >> /config/.zshrc

echo "[laptop-init] Done"
