#!/usr/bin/env bash
# add-agent-web.sh — provision a new single Hermes agent with Envoy OIDC web UI.
#
# Does everything the "add an agent" flow needs:
#   1. creates a Pocket ID OIDC client (+ user group, members, restriction) via API
#   2. writes the Kustomize overlay (app/<name>/) from the agent-web component
#   3. generates + SOPS-encrypts the per-agent secret
#   4. wires a per-agent Flux Kustomization (ks-<name>.yaml)
#   5. registers the KS in the top-level kustomization.yaml
#   6. validates the render
#   7. prints the git commands to commit
#
# Usage:
#   ./add-agent-web.sh <name> [member-username ...]
# Example:
#   ./add-agent-web.sh my-agent alice bob
#
# Env overrides: COMMON_DOMAIN (keiretsu.top), KCTX (ottawa-k8s.keiretsu.ts.net),
#   ADMIN_USER (rajsinghtech), PVC_SIZE (20Gi), POCKET_NS (pocket-id),
#   TAILSCALE_TAG (tag:k8s).
set -euo pipefail

NAME="${1:-}"; shift || true
MEMBERS=("$@")
[[ -z "$NAME" ]] && { echo "usage: $0 <name> [member-username ...]"; exit 1; }
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "name must be kebab-case [a-z0-9-]"; exit 1; }

DOMAIN="${COMMON_DOMAIN:-keiretsu.top}"
KCTX="${KCTX:-ottawa-k8s.keiretsu.ts.net}"
ADMIN_USER="${ADMIN_USER:-rajsinghtech}"
PVC_SIZE="${PVC_SIZE:-20Gi}"
TAG="${TAILSCALE_TAG:-tag:k8s}"
POCKET_NS="${POCKET_NS:-pocket-id}"
PID_URL="https://pocket-id.${DOMAIN}"
HOST="${NAME}.agents.${DOMAIN}"
TAILSCALE_HOSTNAME="${NAME}"
CALLBACK="https://${HOST}/oauth2/callback"

# repo paths (script lives in clusters/<cluster>/apps/agents/)
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SELF_DIR}/app"
OVR_DIR="${APP_DIR}/${NAME}"
CLUSTER_DIR="$(cd "${SELF_DIR}/../.." && pwd)"   # clusters/<cluster> (has .sops.yaml)
COMPONENT_PATH="../../_component/agent-web"        # relative from overlay to component
COOKIES="$(mktemp)"; trap 'rm -f "$COOKIES"' EXIT

api() { curl -fsS -g -b "$COOKIES" -c "$COOKIES" "$@"; }  # authed curl (-g: keep [] literal)
jqp() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

# ---- Pocket ID bootstrapping ----
echo "==> bootstrapping Pocket ID admin session (one-time access token for ${ADMIN_USER})"
POD="$(kubectl get pod -n "$POCKET_NS" -l app.kubernetes.io/name=pocket-id -o name --context="$KCTX" | head -1)"
[[ -z "$POD" ]] && POD="$(kubectl get pod -n "$POCKET_NS" -o name --context="$KCTX" | head -1)"
TOKEN="$(kubectl exec -n "$POCKET_NS" "$POD" --context="$KCTX" -- \
  /app/pocket-id one-time-access-token "$ADMIN_USER" 2>/dev/null | grep -oE '/lc/[A-Za-z0-9]+' | cut -d/ -f3)"
[[ -z "$TOKEN" ]] && { echo "failed to mint one-time access token"; exit 1; }
api -X POST "${PID_URL}/api/one-time-access-token/${TOKEN}" >/dev/null

# ---- OIDC client ----
echo "==> creating OIDC client hermes-${NAME} (idempotent)"
CLIENT_ID="$(api "${PID_URL}/api/oidc/clients?pagination[limit]=200" | \
  python3 -c "import sys,json;print(next((c['id'] for c in json.load(sys.stdin)['data'] if c['name']=='hermes-${NAME}'),''))")"
if [[ -z "$CLIENT_ID" ]]; then
  CLIENT_ID="$(api -X POST "${PID_URL}/api/oidc/clients" -H 'Content-Type: application/json' -d @- <<JSON | jqp "d['id']"
{"name":"hermes-${NAME}","callbackURLs":["${CALLBACK}"],"logoutCallbackURLs":["https://${HOST}"],"isPublic":false,"pkceEnabled":false}
JSON
)"
fi
CLIENT_SECRET="$(api -X POST "${PID_URL}/api/oidc/clients/${CLIENT_ID}/secret" | jqp "d['secret']")"
echo "    clientID=${CLIENT_ID}"

# ---- User group + members ----
echo "==> creating user-group hermes-${NAME}"
GROUP_JSON="$(api -X POST "${PID_URL}/api/user-groups" -H 'Content-Type: application/json' \
  -d "{\"name\":\"hermes-${NAME}\",\"friendlyName\":\"Hermes ${NAME}\"}" 2>/dev/null || true)"
GID="$(printf '%s' "$GROUP_JSON" | jqp "d.get('id','')" 2>/dev/null || true)"
if [[ -z "$GID" ]]; then   # already exists -> look it up
  GID="$(api "${PID_URL}/api/user-groups?pagination[limit]=200" | \
    python3 -c "import sys,json;[print(g['id']) for g in json.load(sys.stdin)['data'] if g['name']=='hermes-${NAME}']")"
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

# ---- Write overlay ----
echo "==> writing overlay ${OVR_DIR}"
mkdir -p "$OVR_DIR"

cat > "${OVR_DIR}/kustomization.yaml" <<YAML
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: agents
components:
  - ${COMPONENT_PATH}
generatorOptions:
  disableNameSuffixHash: true
  annotations:
    config.kubernetes.io/local-config: "true"
configMapGenerator:
  - name: agent-meta
    literals:
      - name=${NAME}
      - host=${HOST//${DOMAIN}/\$\{COMMON_DOMAIN\}}
      - clientID=${CLIENT_ID}
      - size=${PVC_SIZE}
      - tailscaleTag=${TAG}
resources:
  - deployment.yaml
  - configmap.yaml
  - secret.yaml
patches:
  - target:
      kind: ConfigMap
      name: hermes-placeholder-config
    patch: |-
      - op: replace
        path: /data/AGENT_NAME
        value: "${NAME}"
      - op: replace
        path: /data/AGENT_SYSTEM_PROMPT
        value: |
          You are ${NAME}, an AI agent.
          Customize this prompt per agent.
YAML

# Write placeholder deployment
cat > "${OVR_DIR}/deployment.yaml" <<YAML
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: ${NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${NAME}
        agents.keiretsu.ts.net/persona: assistant
        agents.keiretsu.ts.net/owner: ${NAME}
    spec:
      containers:
        - name: gateway
          image: nousresearch/hermes-agent:v2026.6.5
          args: ["gateway", "run"]
          envFrom:
            - configMapRef:
                name: ${NAME}-config
            - secretRef:
                name: ${NAME}-secrets
          env:
            - name: HERMES_DASHBOARD
              value: "1"
            - name: HERMES_DASHBOARD_HOST
              value: "0.0.0.0"
            - name: HERMES_DASHBOARD_PORT
              value: "9119"
            - name: HERMES_DASHBOARD_INSECURE
              value: "1"
          ports:
            - name: gateway
              containerPort: 8642
              protocol: TCP
            - name: dashboard
              containerPort: 9119
              protocol: TCP
          resources:
            requests:
              cpu: 1000m
              memory: 2Gi
            limits:
              memory: 6Gi
          volumeMounts:
            - name: data
              mountPath: /opt/data
            - name: shm
              mountPath: /dev/shm
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: ${NAME}-data
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 2Gi
      terminationGracePeriodSeconds: 30
YAML

cat > "${OVR_DIR}/configmap.yaml" <<YAML
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-placeholder-config
data:
  GATEWAY_ALLOW_ALL_USERS: "true"
  API_SERVER_ENABLED: "true"
  API_SERVER_HOST: "0.0.0.0"
  API_SERVER_PORT: "8642"
  API_SERVER_KEY: "\${DEFAULT_PASSWORD}"
  AGENT_NAME: "${NAME}"
  AGENT_PERSONA: "assistant"
  AGENT_SYSTEM_PROMPT: |
    You are ${NAME}, an AI agent.
    Customize this prompt per agent.
YAML

cat > "${OVR_DIR}/secret.yaml" <<YAML
---
apiVersion: v1
kind: Secret
metadata:
  name: ${NAME}-secrets
type: Opaque
stringData:
  API_SERVER_KEY: "$(openssl rand -hex 24)"
  # Add per-agent secrets below:
  # DISCORD_BOT_TOKEN: ""
  # GOOGLE_OAUTH_CLIENT_ID: ""
  # GOOGLE_OAUTH_CLIENT_SECRET: ""
  # NOTION_TOKEN: ""
---
apiVersion: v1
kind: Secret
metadata:
  name: ${NAME}-oidc
type: Opaque
stringData:
  client-secret: "${CLIENT_SECRET}"
YAML

echo "==> encrypting secrets with SOPS"
( cd "$CLUSTER_DIR" && sops --encrypt --in-place "apps/agents/app/${NAME}/secret.yaml" )

echo "==> writing per-agent Flux Kustomization"
cat > "${SELF_DIR}/ks-${NAME}.yaml" <<YAML
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agents-${NAME}
  namespace: flux-system
spec:
  targetNamespace: agents
  commonMetadata:
    labels:
      app.kubernetes.io/name: agents-${NAME}
  path: ./clusters/\${CLUSTER_NAME}/apps/agents/app/${NAME}
  prune: true
  dependsOn:
    - name: agents
  sourceRef:
    kind: GitRepository
    name: kubernetes-manifests
  interval: 30m
  retryInterval: 1m
  timeout: 5m
  decryption:
    provider: sops
    secretRef:
      name: sops-gpg
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: common-settings
      - kind: Secret
        name: common-secrets
      - kind: ConfigMap
        name: cluster-settings
        optional: true
      - kind: Secret
        name: cluster-secrets
        optional: true
YAML

echo "==> registering ks-${NAME}.yaml in kustomization.yaml"
grep -qE "^\s*-\s+ks-${NAME}\.yaml\s*$" "${SELF_DIR}/kustomization.yaml" || \
  printf '  - ks-%s.yaml\n' "$NAME" >> "${SELF_DIR}/kustomization.yaml"

echo "==> validating render"
kustomize build "$OVR_DIR" >/dev/null && echo "    overlay render OK"

cat <<DONE

✅ agent '${NAME}' provisioned.
   URL:       https://${HOST}
   client:    hermes-${NAME} (${CLIENT_ID})  restricted to group hermes-${NAME}
   members:   ${MEMBERS[*]:-<none — add them in Pocket ID>}

Commit + push to roll it out (Flux reconciles in ~30m, or force it):
   kubectl config use-context ${KCTX}
   cd ${CLUSTER_DIR}
   git add apps/agents/app/${NAME} apps/agents/ks-${NAME}.yaml apps/agents/kustomization.yaml
   git commit -m "feat(agents): add ${NAME} agent"
   git push origin main
   flux reconcile kustomization cluster-apps  # picks up the new ks
   flux reconcile kustomization agents-${NAME}
DONE