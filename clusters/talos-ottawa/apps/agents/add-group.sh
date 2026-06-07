#!/usr/bin/env bash
# add-group.sh — provision a new multi-tenant Hermes group end to end.
#
# Does everything the design's "add a group" flow needs:
#   1. creates a Pocket ID OIDC client (+ user group, members, restriction) via API
#   2. writes the Kustomize overlay (groups/<name>/) from the hermes-group component
#   3. generates + SOPS-encrypts the per-group secret
#   4. wires the overlay into app/kustomization.yaml
#   5. validates the render
# It does NOT git commit/push — it prints the commands so you stay in control.
#
# Usage:
#   ./add-group.sh <group> [member-username ...]
# Example:
#   ./add-group.sh acme alice bob
#
# Env overrides: COMMON_DOMAIN (keiretsu.top), KCTX (ottawa-k8s.keiretsu.ts.net),
#   ADMIN_USER (rajsinghtech), PVC_SIZE (20Gi), POCKET_NS (pocket-id).
set -euo pipefail

GROUP="${1:-}"; shift || true
MEMBERS=("$@")
[[ -z "$GROUP" ]] && { echo "usage: $0 <group> [member-username ...]"; exit 1; }
[[ "$GROUP" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "group must be kebab-case [a-z0-9-]"; exit 1; }

DOMAIN="${COMMON_DOMAIN:-keiretsu.top}"
KCTX="${KCTX:-ottawa-k8s.keiretsu.ts.net}"
ADMIN_USER="${ADMIN_USER:-rajsinghtech}"
PVC_SIZE="${PVC_SIZE:-20Gi}"
POCKET_NS="${POCKET_NS:-pocket-id}"
PID_URL="https://pocket-id.${DOMAIN}"
HOST="${GROUP}.agents.${DOMAIN}"
CALLBACK="https://${HOST}/oauth2/callback"

# repo paths (script lives in clusters/talos-ottawa/apps/agents/)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SELF_DIR}/app"
OVR_DIR="${APP_DIR}/groups/${GROUP}"
OTTAWA_DIR="$(cd "${SELF_DIR}/../.." && pwd)"   # clusters/talos-ottawa (has .sops.yaml)
COOKIES="$(mktemp)"; trap 'rm -f "$COOKIES"' EXIT

api() { curl -fsS -g -b "$COOKIES" -c "$COOKIES" "$@"; }  # authed curl (-g: keep [] literal)
jqp() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

echo "==> bootstrapping Pocket ID admin session (one-time access token for ${ADMIN_USER})"
POD="$(kubectl get pod -n "$POCKET_NS" -l app.kubernetes.io/name=pocket-id -o name --context="$KCTX" | head -1)"
[[ -z "$POD" ]] && POD="$(kubectl get pod -n "$POCKET_NS" -o name --context="$KCTX" | head -1)"
TOKEN="$(kubectl exec -n "$POCKET_NS" "$POD" --context="$KCTX" -- \
  /app/pocket-id one-time-access-token "$ADMIN_USER" 2>/dev/null | grep -oE '/lc/[A-Za-z0-9]+' | cut -d/ -f3)"
[[ -z "$TOKEN" ]] && { echo "failed to mint one-time access token"; exit 1; }
api -X POST "${PID_URL}/api/one-time-access-token/${TOKEN}" >/dev/null

echo "==> creating OIDC client hermes-${GROUP} (idempotent)"
CLIENT_ID="$(api "${PID_URL}/api/oidc/clients?pagination[limit]=200" | \
  python3 -c "import sys,json;print(next((c['id'] for c in json.load(sys.stdin)['data'] if c['name']=='hermes-${GROUP}'),''))")"
if [[ -z "$CLIENT_ID" ]]; then
  CLIENT_ID="$(api -X POST "${PID_URL}/api/oidc/clients" -H 'Content-Type: application/json' -d @- <<JSON | jqp "d['id']"
{"name":"hermes-${GROUP}","callbackURLs":["${CALLBACK}"],"logoutCallbackURLs":["https://${HOST}"],"isPublic":false,"pkceEnabled":false}
JSON
)"
fi
CLIENT_SECRET="$(api -X POST "${PID_URL}/api/oidc/clients/${CLIENT_ID}/secret" | jqp "d['secret']")"
echo "    clientID=${CLIENT_ID}"

echo "==> creating user-group hermes-${GROUP}"
GROUP_JSON="$(api -X POST "${PID_URL}/api/user-groups" -H 'Content-Type: application/json' \
  -d "{\"name\":\"hermes-${GROUP}\",\"friendlyName\":\"Hermes ${GROUP}\"}" 2>/dev/null || true)"
GID="$(printf '%s' "$GROUP_JSON" | jqp "d.get('id','')" 2>/dev/null || true)"
if [[ -z "$GID" ]]; then   # already exists -> look it up
  GID="$(api "${PID_URL}/api/user-groups?pagination[limit]=200" | \
    python3 -c "import sys,json;[print(g['id']) for g in json.load(sys.stdin)['data'] if g['name']=='hermes-${GROUP}']")"
fi
[[ -z "$GID" ]] && { echo "could not create/find user-group"; exit 1; }

if [[ ${#MEMBERS[@]} -gt 0 ]]; then
  echo "==> resolving + adding members: ${MEMBERS[*]}"
  IDS="$(for u in "${MEMBERS[@]}"; do
    api "${PID_URL}/api/users?pagination[limit]=200&search=${u}" | \
      U="$u" python3 -c "import sys,json,os;u=os.environ['U'];[print(x['id']) for x in json.load(sys.stdin)['data'] if x['username']==u]"
  done)"
  BODY="$(python3 -c "import sys;print(__import__('json').dumps({'userIds':sys.stdin.read().split()}))" <<<"$IDS")"
  api -X PUT "${PID_URL}/api/user-groups/${GID}/users" -H 'Content-Type: application/json' -d "$BODY" >/dev/null
fi

echo "==> restricting client to group (only members can authenticate)"
api -X PUT "${PID_URL}/api/oidc/clients/${CLIENT_ID}/allowed-user-groups" \
  -H 'Content-Type: application/json' -d "{\"userGroupIds\":[\"${GID}\"]}" >/dev/null

echo "==> writing overlay ${OVR_DIR}"
mkdir -p "$OVR_DIR"
cat > "${OVR_DIR}/kustomization.yaml" <<YAML
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: agents
components:
  - ../../_component/hermes-group
generatorOptions:
  # group-meta only feeds the component's replacements; local-config keeps it out
  # of the applied output so this group's Flux Kustomization never tries to own a
  # ConfigMap/group-meta (which would clash with other groups in the namespace).
  disableNameSuffixHash: true
  annotations:
    config.kubernetes.io/local-config: "true"
configMapGenerator:
  - name: group-meta
    literals:
      - name=${GROUP}
      - host=${HOST//${DOMAIN}/\$\{COMMON_DOMAIN\}}
      - clientID=${CLIENT_ID}
      - size=${PVC_SIZE}
resources:
  - secret.sops.yaml
patches:
  - target:
      kind: ConfigMap
      name: hermes-placeholder-config
    patch: |-
      - op: replace
        path: /data/AGENT_SYSTEM_PROMPT
        value: |
          You are the ${GROUP} group's shared assistant.
          Keep answers terse and technical.
YAML

cat > "${OVR_DIR}/secret.sops.yaml" <<YAML
---
apiVersion: v1
kind: Secret
metadata:
  name: hermes-${GROUP}-secrets
type: Opaque
stringData:
  API_SERVER_KEY: "$(openssl rand -hex 24)"
---
apiVersion: v1
kind: Secret
metadata:
  name: hermes-${GROUP}-oidc
type: Opaque
stringData:
  client-secret: "${CLIENT_SECRET}"
YAML

echo "==> encrypting secret with SOPS"
( cd "$OTTAWA_DIR" && sops --encrypt --in-place "apps/agents/app/groups/${GROUP}/secret.sops.yaml" )

echo "==> writing per-group Flux Kustomization ks-${GROUP}.yaml"
sed "s/demo/${GROUP}/g" "${SELF_DIR}/ks-demo.yaml" > "${SELF_DIR}/ks-${GROUP}.yaml"

echo "==> registering ks-${GROUP}.yaml in kustomization.yaml"
grep -qE "^\s*-\s+ks-${GROUP}\.yaml\s*$" "${SELF_DIR}/kustomization.yaml" || \
  printf '  - ks-%s.yaml\n' "$GROUP" >> "${SELF_DIR}/kustomization.yaml"

echo "==> validating render"
kustomize build "$OVR_DIR" >/dev/null && echo "    overlay render OK"

cat <<DONE

✅ group '${GROUP}' provisioned.
   URL:      https://${HOST}
   client:   hermes-${GROUP} (${CLIENT_ID})  restricted to group hermes-${GROUP}
   members:  ${MEMBERS[*]:-<none — add them in Pocket ID>}

Commit + push to roll it out (Flux reconciles in ~30m, or force it):
   git add clusters/talos-ottawa/apps/agents/app/groups/${GROUP} \\
           clusters/talos-ottawa/apps/agents/ks-${GROUP}.yaml \\
           clusters/talos-ottawa/apps/agents/kustomization.yaml
   git commit -m "feat(agents): add ${GROUP} group"
   git push origin main
   flux reconcile kustomization cluster-apps --context=${KCTX}   # picks up the new ks
   flux reconcile kustomization agents-${GROUP} --context=${KCTX}
DONE
