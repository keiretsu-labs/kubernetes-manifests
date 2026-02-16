#!/usr/bin/env bash
set -e

echo "[laptop-init] Configuring git..."
git config --global user.name "rajsinghtechbot"
git config --global user.email "king360raj@gmail.com"
git config --global credential.https://github.com.helper \
  '!f() { echo "username=x-access-token"; echo "password=$GITHUB_TOKEN"; }; f'

echo "[laptop-init] Setting up workspace..."
mkdir -p /home/coder/workspace
if [ ! -d /home/coder/workspace/kubernetes-manifests/.git ]; then
  echo "[laptop-init] Cloning kubernetes-manifests..."
  git clone https://github.com/rajsinghtech/kubernetes-manifests.git /home/coder/workspace/kubernetes-manifests
else
  echo "[laptop-init] kubernetes-manifests already cloned, skipping"
fi

echo "[laptop-init] Configuring Claude Code..."
if [ -f /home/coder/.claude.json ]; then
  python3 -c "
import json
with open('/home/coder/.claude.json', 'r') as f:
    d = json.load(f)
d['hasCompletedOnboarding'] = True
with open('/home/coder/.claude.json', 'w') as f:
    json.dump(d, f, indent=2)
"
else
  echo '{"hasCompletedOnboarding":true}' > /home/coder/.claude.json
fi

echo "[laptop-init] Configuring shell..."
touch /home/coder/.zshrc
grep -q 'KUBECONFIG' /home/coder/.zshrc 2>/dev/null || echo 'export KUBECONFIG=/home/coder/.kube/config' >> /home/coder/.zshrc

echo "[laptop-init] Done"
