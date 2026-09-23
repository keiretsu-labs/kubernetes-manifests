# shellcheck shell=sh
# Single source of truth for the cliproxy -> per-agent variable mapping.
#
# Sourced from two places, because no one mechanism covers every caller:
#   custom-cont-init.d/10-bot-environment  -> pushes these into s6's
#       container environment, which is what reaches the desktop session and
#       anything launched from a GUI menu.
#   /etc/profile.d/90-bot-tooling.sh       -> exports them for shells,
#       including `kubectl exec`, which starts from the container's original
#       environment and never sees /run/s6/container_environment.
#
# Sets the variables without exporting and lists their names in
# BOT_AGENT_VARS so each caller can do the right thing with them.
# Every variable below is consumed by whoever sources this file.
# shellcheck disable=SC2034
BOT_AGENT_VARS=""

if [ -n "${CLIPROXY_BASE_URL:-}" ]; then
  _bot_base="${CLIPROXY_BASE_URL%/}"

  # OpenAI-compatible: /v1/responses and /v1/chat/completions.
  OPENAI_BASE_URL="${_bot_base}/v1"
  OPENAI_API_KEY="${CLIPROXY_API_KEY:-}"

  # Anthropic-compatible: Claude Code appends /v1/messages itself.
  ANTHROPIC_BASE_URL="${_bot_base}"
  ANTHROPIC_AUTH_TOKEN="${CLIPROXY_API_KEY:-}"

  # Gemini-compatible.
  GOOGLE_GEMINI_BASE_URL="${_bot_base}/v1beta"
  GEMINI_API_KEY="${CLIPROXY_API_KEY:-}"

  BOT_AGENT_VARS="OPENAI_BASE_URL OPENAI_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN GOOGLE_GEMINI_BASE_URL GEMINI_API_KEY"

  unset _bot_base
fi
