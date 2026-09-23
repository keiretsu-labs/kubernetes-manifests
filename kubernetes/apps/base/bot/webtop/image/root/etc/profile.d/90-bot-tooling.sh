# shellcheck shell=sh
# Shell setup for the single desktop user.
#
# Absolute toolchain paths are also Dockerfile ENV, which covers the desktop
# session and non-login shells. They are repeated here because Debian's
# /etc/profile *rewrites* PATH from scratch for login shells, dropping
# /opt/go/bin and /opt/node/bin. /lsiopy/bin is deliberately not re-added: it
# is LinuxServer's service venv, not something a user shell should shadow
# python3 with.
_bot_home="${HOME:-/config}"

export GOPATH="${_bot_home}/go"
export GOBIN="${GOPATH}/bin"
export GOMODCACHE="${GOPATH}/pkg/mod"

# Keep user-level `npm i -g` and every package cache on the home volume so the
# image layers stay read-only in practice.
export npm_config_cache="${_bot_home}/.npm"
export npm_config_prefix="${_bot_home}/.local"
export UV_CACHE_DIR="${_bot_home}/.cache/uv"
export UV_PYTHON_INSTALL_DIR="${_bot_home}/.local/share/uv/python"

for _d in "${_bot_home}/.local/bin" "${GOBIN}" /opt/go/bin /opt/node/bin; do
  case ":${PATH}:" in
    *":${_d}:"*) ;;
    *) PATH="${_d}:${PATH}" ;;
  esac
done
export PATH
unset _d

# `kubectl exec` starts from the container's original environment and never
# sees /run/s6/container_environment, so re-derive the agent variables here.
if [ -r /etc/bot/agent-env.sh ]; then
  # shellcheck source=/dev/null
  . /etc/bot/agent-env.sh
  for _v in ${BOT_AGENT_VARS}; do
    # ${_v?} rather than ${_v}: both export the *named* variable, but the
    # former is how shellcheck is told that is intentional (SC2163).
    export "${_v?}"
  done
  unset _v BOT_AGENT_VARS
fi

unset _bot_home
