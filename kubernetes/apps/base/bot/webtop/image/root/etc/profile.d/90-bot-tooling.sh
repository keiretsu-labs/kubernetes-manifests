# shellcheck shell=sh
# Home-relative tool configuration for the single desktop user.
#
# Absolute, image-wide values (GOROOT, the toolchain PATH entries) are set as
# Dockerfile ENV so every process gets them. Only things that hang off $HOME
# belong here, because HOME is the /config volume and is not known at build time.
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

case ":${PATH}:" in
  *":${GOBIN}:"*) ;;
  *) PATH="${_bot_home}/.local/bin:${GOBIN}:${PATH}" ;;
esac
export PATH

unset _bot_home
