#!/usr/bin/env bash
# Build-time provisioner for the bot/webtop maintainer image.
#
# Stage dispatch keeps each concern in its own Docker layer while the logic
# stays in one reviewable file:
#
#   install.sh system   distro packages via the detected package manager
#   install.sh langs    Go, Node, uv (Python)
#   install.sh tools    kubernetes/gitops CLIs
#   install.sh agents   herdr, codex, claude code
#
# Nothing here writes to /config. /config is the LinuxServer volume and is
# masked at runtime by the mount, so anything seeded at build time would
# vanish. Runtime seeding lives in root/custom-cont-init.d/.
set -euo pipefail

readonly PREFIX=/usr/local
readonly OPT=/opt

log() { printf '\n==> %s\n' "$*"; }

# --- platform detection ------------------------------------------------------

# LinuxServer publishes webtop on debian, ubuntu, alpine, arch and fedora
# bases. Resolving the package manager instead of hardcoding apt is what makes
# WEBTOP_BASE_TAG genuinely swappable.
detect_pkg() {
  for mgr in apt-get apk pacman dnf; do
    if command -v "$mgr" >/dev/null 2>&1; then echo "$mgr"; return 0; fi
  done
  echo "install.sh: no supported package manager found" >&2
  return 1
}

# Two naming conventions are in play across upstreams, so expose both.
#   ARCH_GO    amd64 / arm64   (go, kubectl, helm, flux, ...)
#   ARCH_RUST  x86_64 / aarch64 (herdr, codex, uv)
arch_init() {
  case "$(uname -m)" in
    x86_64)  ARCH_GO=amd64; ARCH_RUST=x86_64;  ARCH_NODE=x64 ;;
    aarch64|arm64) ARCH_GO=arm64; ARCH_RUST=aarch64; ARCH_NODE=arm64 ;;
    *) echo "install.sh: unsupported architecture $(uname -m)" >&2; return 1 ;;
  esac
  readonly ARCH_GO ARCH_RUST ARCH_NODE
}

# --- fetch helpers -----------------------------------------------------------

# fetch <url> <dest>
fetch() {
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --output "$2" "$1"
}

# install_bin <url> <name>  — single-binary release asset
install_bin() {
  local url=$1 name=$2
  log "$name"
  fetch "$url" "$PREFIX/bin/$name"
  chmod 0755 "$PREFIX/bin/$name"
}

# install_tgz <url> <name> <path-inside-archive>
# Strips the archive's own directory layout so every tool lands flat in
# /usr/local/bin regardless of how upstream packages it.
install_tgz() {
  local url=$1 name=$2 inner=$3 tmp
  log "$name"
  tmp=$(mktemp -d)
  fetch "$url" "$tmp/archive"
  tar -xf "$tmp/archive" -C "$tmp"
  install -m 0755 "$tmp/$inner" "$PREFIX/bin/$name"
  rm -rf "$tmp"
}

# --- stages ------------------------------------------------------------------

stage_system() {
  local mgr
  mgr=$(detect_pkg)
  log "system packages via $mgr"

  # Deliberately modest: the desktop already ships a browser, a terminal and a
  # file manager. This adds what a Go/Python/JS maintainer reaches for in a
  # shell, plus the build toolchain cgo and native npm modules need.
  local common=(
    bash bash-completion ca-certificates curl wget git git-lfs gnupg
    jq less make openssh-client rsync socat tar tmux tree unzip vim xz-utils
    zip zsh
  )

  case "$mgr" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends \
        "${common[@]}" \
        build-essential pkg-config python3 python3-venv \
        bind9-dnsutils iputils-ping netcat-openbsd \
        fd-find ripgrep fzf htop shellcheck
      # Debian ships fd as fdfind to avoid a name clash with an unrelated package.
      ln -sf "$(command -v fdfind)" "$PREFIX/bin/fd"
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      apk add --no-cache \
        "${common[@]}" \
        build-base pkgconf python3 \
        bind-tools iputils netcat-openbsd \
        fd ripgrep fzf htop shellcheck
      ;;
    pacman)
      pacman -Sy --noconfirm --needed \
        "${common[@]}" \
        base-devel pkgconf python \
        bind iputils openbsd-netcat \
        fd ripgrep fzf htop shellcheck
      ;;
    dnf)
      dnf install -y \
        "${common[@]}" \
        gcc gcc-c++ pkgconf python3 \
        bind-utils iputils nmap-ncat \
        fd-find ripgrep fzf htop ShellCheck
      dnf clean all
      ;;
  esac
}

stage_langs() {
  log "go ${GO_VERSION}"
  fetch "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH_GO}.tar.gz" /tmp/go.tgz
  rm -rf "$OPT/go"
  tar -C "$OPT" -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz

  # GOPATH/GOBIN live under /config at runtime (see custom-cont-init.d), so the
  # only thing that belongs in the image is the toolchain itself.
  log "node ${NODE_VERSION}"
  fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${ARCH_NODE}.tar.xz" /tmp/node.txz
  rm -rf "$OPT/node"
  mkdir -p "$OPT/node"
  tar -C "$OPT/node" --strip-components=1 -xJf /tmp/node.txz
  rm -f /tmp/node.txz
  # corepack gives pnpm and yarn without pinning either one here.
  "$OPT/node/bin/corepack" enable --install-directory "$OPT/node/bin"

  install_tgz \
    "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${ARCH_RUST}-unknown-linux-gnu.tar.gz" \
    uv "uv-${ARCH_RUST}-unknown-linux-gnu/uv"
  install_tgz \
    "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${ARCH_RUST}-unknown-linux-gnu.tar.gz" \
    uvx "uv-${ARCH_RUST}-unknown-linux-gnu/uvx"

  install_tgz \
    "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION}-linux-${ARCH_GO}.tar.gz" \
    golangci-lint "golangci-lint-${GOLANGCI_LINT_VERSION}-linux-${ARCH_GO}/golangci-lint"
}

stage_tools() {
  install_bin \
    "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH_GO}/kubectl" \
    kubectl
  install_bin \
    "https://github.com/siderolabs/talos/releases/download/v${TALOSCTL_VERSION}/talosctl-linux-${ARCH_GO}" \
    talosctl
  install_bin \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${ARCH_GO}" \
    sops
  install_bin \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH_GO}" \
    yq

  install_tgz \
    "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH_GO}.tar.gz" \
    helm "linux-${ARCH_GO}/helm"
  install_tgz \
    "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_${ARCH_GO}.tar.gz" \
    flux flux
  install_tgz \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_${ARCH_GO}.tar.gz" \
    kustomize kustomize
  install_tgz \
    "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${ARCH_GO}.tar.gz" \
    age age/age
  install_tgz \
    "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${ARCH_GO}.tar.gz" \
    age-keygen age/age-keygen
  install_tgz \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH_GO}.tar.gz" \
    gh "gh_${GH_VERSION}_linux_${ARCH_GO}/bin/gh"
}

stage_agents() {
  install_bin \
    "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${ARCH_RUST}" \
    herdr

  # The codex release asset is a bare binary inside the tarball, named after
  # the target triple rather than "codex".
  install_tgz \
    "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-${ARCH_RUST}-unknown-linux-musl.tar.gz" \
    codex "codex-${ARCH_RUST}-unknown-linux-musl"

  log "claude code ${CLAUDE_CODE_VERSION}"
  "$OPT/node/bin/npm" install -g --no-fund --no-audit \
    "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
  ln -sf "$OPT/node/bin/claude" "$PREFIX/bin/claude"
}

main() {
  local stage=${1:?usage: install.sh <system|langs|tools|agents>}
  arch_init
  case "$stage" in
    system) stage_system ;;
    langs)  stage_langs ;;
    tools)  stage_tools ;;
    agents) stage_agents ;;
    *) echo "install.sh: unknown stage '$stage'" >&2; return 2 ;;
  esac
}

main "$@"
