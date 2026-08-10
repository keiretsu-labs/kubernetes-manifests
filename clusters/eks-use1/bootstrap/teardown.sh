#!/usr/bin/env bash
# Tear down eks-use1 AWS infra + purge matching tailnet devices.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
export AWS_PROFILE="${AWS_PROFILE:-tailscale-sandbox}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-eks-use1}"

echo "==> eksctl delete cluster $CLUSTER"
eksctl delete cluster -f clusters/eks-use1/bootstrap/eksctl-cluster.yaml --wait

echo "==> purge tailnet devices matching $CLUSTER"
OID="$(sops -d --extract '["stringData"]["TS_OAUTH_CLIENT_ID"]' clusters/common/flux/vars/common-secrets.sops.yaml)"
OSEC="$(sops -d --extract '["stringData"]["TS_OAUTH_CLIENT_SECRET"]' clusters/common/flux/vars/common-secrets.sops.yaml)"
TAILNET="$(sops -d --extract '["stringData"]["TAILSCALE_TAILNET"]' clusters/common/flux/vars/common-secrets.sops.yaml)"
TOKEN="$(curl -sS -d "client_id=${OID}&client_secret=${OSEC}" https://api.tailscale.com/api/v2/oauth/token \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')"

TOKEN="$TOKEN" CLUSTER="$CLUSTER" curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://api.tailscale.com/api/v2/tailnet/${TAILNET}/devices" \
  | TOKEN="$TOKEN" CLUSTER="$CLUSTER" python3 -c '
import json,sys,urllib.request,os
token=os.environ["TOKEN"]
match=os.environ.get("CLUSTER","eks-use1")
devs=json.load(sys.stdin)["devices"]
for x in devs:
  hn=(x.get("hostname") or "")
  name=(x.get("name") or "")
  if match not in hn and match not in name:
    continue
  did=x["id"]
  req=urllib.request.Request(
    f"https://api.tailscale.com/api/v2/device/{did}",
    method="DELETE",
    headers={"Authorization": f"Bearer {token}"},
  )
  try:
    urllib.request.urlopen(req)
    print("deleted", did, hn or name)
  except Exception as e:
    print("fail", did, hn or name, e)
' 

echo "==> done"
