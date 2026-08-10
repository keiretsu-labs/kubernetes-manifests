#!/usr/bin/env bash
# Bootstrap AWS LBC + Flux + SOPS + GitHub token onto eks-use1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

CLUSTER="${CLUSTER:-eks-use1}"
REGION="${AWS_REGION:-us-east-1}"
export AWS_PROFILE="${AWS_PROFILE:-tailscale-sandbox}"

echo "==> kubeconfig for $CLUSTER"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl config current-context
kubectl get nodes -o wide

echo "==> AWS Load Balancer Controller (needed for UDP NLB peer-relay)"
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER" --region "$REGION" --approve || true
# IAM policy
POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`AWSLoadBalancerControllerIAMPolicy`].Arn' --output text)
if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" = "None" ]; then
  curl -fsSL -o /tmp/iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
  POLICY_ARN=$(aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file:///tmp/iam_policy.json \
    --query Policy.Arn --output text)
fi
echo "LBC policy: $POLICY_ARN"
eksctl create iamserviceaccount \
  --cluster "$CLUSTER" --region "$REGION" \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn "$POLICY_ARN" \
  --approve --override-existing-serviceaccounts || true

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update eks
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.resourcesVpcConfig.vpcId' --output text)
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --wait --timeout 5m

echo "==> install Flux controllers"
kubectl apply --server-side -k clusters/common/bootstrap/flux

echo "==> wait for flux-system"
kubectl -n flux-system wait --for=condition=Available deploy --all --timeout=5m

echo "==> sops-gpg secret"
# Strip cluster-specific metadata (uid/resourceVersion) from the tracked secret.
python3 - <<'PY2'
import yaml
from pathlib import Path
doc = yaml.safe_load(Path("clusters/common/bootstrap/flux/secret.yaml").read_text())
meta = doc.get("metadata", {})
doc["metadata"] = {k: meta[k] for k in ("name", "namespace") if k in meta}
Path("/tmp/sops-gpg.yaml").write_text(yaml.dump(doc, default_flow_style=False))
PY2
kubectl apply -f /tmp/sops-gpg.yaml

echo "==> github token for GitRepository"
GH_TOKEN="$(sops -d --extract '["stringData"]["KUBERNETES_MANIFESTS_GITHUB_TOKEN"]' \
  clusters/common/flux/vars/common-secrets.sops.yaml)"
kubectl -n flux-system create secret generic kubernetes-manifests-github-token \
  --from-literal=username=git \
  --from-literal=password="$GH_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> apply cluster flux config (GitRepository + root Kustomizations)"
kubectl apply -f clusters/eks-use1/flux/config/cluster.yaml

echo "==> kick reconcile"
kubectl -n flux-system annotate gitrepository kubernetes-manifests \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite || true

echo "==> status"
flux get all -A || true
echo "Done. Watch: flux get ks -A"
