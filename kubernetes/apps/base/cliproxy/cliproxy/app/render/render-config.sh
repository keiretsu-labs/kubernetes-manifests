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
set -eu
umask 077

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
api-keys:
  - "$${API_KEY}"
# Every credential owns its native route prefix. OAuth prefixes
# live in auth metadata; the generated compatible providers
# declare the Tailscale-backed routes below.
force-model-prefix: true
# Keep a stable, GitOps-owned fallback in the Codex subscription
# pool while the Vision-Exp route is unavailable.
oauth-model-alias:
  codex:
    - name: "gpt-5.6-luna"
      alias: "vllm-fallback"
      display-name: "Codex subscription fallback"
      fork: true
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
EOF
cat /provider/providers.yaml >> /config/.config.yaml.tmp
mv /config/.config.yaml.tmp /config/config.yaml
