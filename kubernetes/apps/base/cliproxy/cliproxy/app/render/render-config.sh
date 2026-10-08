# Render /config/config.yaml from this static head plus the GitOps provider
# catalog at /provider/providers.yaml.
#
# This lives in a file rather than inline in the Deployment because two things
# run it: the init container, which must produce a config before CLIProxy
# starts, and the watch sidecar, which re-renders when the catalog ConfigMap
# changes. Inlining it twice would be two copies of the same 80 lines drifting
# apart on the next edit.
#
# CLIProxyAPI watches this path with fsnotify and compares a content hash, so
# the swap at the end must be atomic: a half-written file would otherwise be
# read as a live config.
#
# Workspace client keys live in /workspace-keys (one file per V1 slug, from
# Secret/cliproxy-workspace-keys). They must be written into api-keys here:
# a catalog reload replaces the in-memory list with this file, and V1 no
# longer re-PATCHes /v0/management/api-keys afterward.
set -eu
umask 077

append_workspace_api_keys() {
  keys_dir=/workspace-keys
  if [ ! -d "$${keys_dir}" ]; then
    echo "render-config: workspace keys directory missing" >&2
    return 1
  fi
  found=0
  for f in "$${keys_dir}"/*; do
    [ -e "$${f}" ] || {
      echo "render-config: no workspace key files under $${keys_dir}" >&2
      return 1
    }
    [ -f "$${f}" ] || continue
    name=$$(basename "$${f}")
    case "$${name}" in
      ..*) continue ;;
    esac
    key=$$(tr -d '\n' < "$${f}")
    if [ -z "$${key}" ]; then
      echo "render-config: empty workspace key file $${name}" >&2
      return 1
    fi
    case "$${key}" in
      *\"*|*"'"*|*"\\"*|*"$$"*)
        echo "render-config: workspace key file $${name} is not a plain token" >&2
        return 1
        ;;
    esac
    printf '  - "%s"\n' "$${key}" >> /config/.config.yaml.tmp
    found=$$((found + 1))
  done
  if [ "$${found}" -eq 0 ]; then
    echo "render-config: no workspace key files under $${keys_dir}" >&2
    return 1
  fi
}

cat > /config/.config.yaml.tmp <<EOF
host: ""
port: 8317
auth-dir: /data/auth
tls:
  enable: false
  cert: ""
  key: ""
remote-management:
  allow-remote: true
  secret-key: "$${MANAGEMENT_KEY}"
  disable-control-panel: false
  disable-auto-update-panel: true
# Every credential owns its native route prefix. OAuth prefixes
# live in auth metadata; the generated compatible providers
# declare the Tailscale-backed routes below.
force-model-prefix: true
plugins:
  enabled: true
  dir: "/CLIProxyAPI/plugins"
  configs:
    pi-bridge:
      enabled: true
      priority: 3
      store:
        version: "0.9.1"
      allow_all_api_keys: true
debug: false
pprof:
  enable: false
  addr: "127.0.0.1:8316"
logging-to-file: true
# Keep operational logs bounded on the dedicated PVC. Full
# request-body logging produced one multi-megabyte artifact per
# request and exhausted the 20Gi claim before the old age-based
# cleanup could catch up.
logs-max-total-size-mb: 256
request-log: false
usage-statistics-enabled: false
ws-auth: true
routing:
  strategy: round-robin
  # Affinity is deliberate: it keeps one conversation on one
  # subscription so the account's prompt cache keeps hitting.
  # It is not what blocked failover -- request-retry was.
  session-affinity: true
# Additional credential retry rounds. These rounds are what
# handle 403/408/429/500/502/503/504, so leaving this at 0
# meant a rate-limited subscription returned the 429 straight
# to the client instead of moving to the next credential. A
# disabled or throttled account now falls through to a healthy
# one. Upstream's own default is 3.
request-retry: 3
# Allow a bounded wait for a cooling credential before starting
# another round; 0 forbade every positive cooldown wait.
max-retry-interval: 30
# St. Petersburg's GLM vLLM endpoint accepts system messages but
# rejects OpenAI's developer role, which Pi sends by default.
# Keep this compatibility translation scoped to the GLM alias.
payload:
  override:
    - models:
        - name: "vllm/GLM-5.3-Flash-EXL3"
          protocol: "openai"
      params:
        'messages.#(role=="developer")#.role': system
# api-keys is last in this head so append_workspace_api_keys can extend
# the list without splicing the rest of the document. A catalog reload
# replaces the in-memory list with this file.
api-keys:
  - "$${API_KEY}"
EOF
append_workspace_api_keys
cat /provider/providers.yaml >> /config/.config.yaml.tmp
mv /config/.config.yaml.tmp /config/config.yaml
