# Maintainer desktop for the `bot` namespace: LinuxServer's webtop plus the
# Go/Python/JS and GitOps toolchain, wired to cliproxy.
#
# Two LinuxServer rules shape this whole file:
#
#   1. The base image's ENTRYPOINT (/init, s6-overlay) is never overridden.
#      There is deliberately no ENTRYPOINT or CMD below -- s6 stays PID 1 and
#      keeps owning PUID/PGID remapping, the desktop, and Selkies.
#   2. /config is the volume and the single desktop user's ~. Nothing is
#      written there at build time; it would be masked by the mount. Runtime
#      seeding lives in root/custom-cont-init.d/, which is LinuxServer's
#      documented extension point.
#
# The base is an ARG so the desktop flavour stays swappable -- debian-xfce,
# debian-kde, ubuntu-mate, alpine-xfce and friends all work, because
# install.sh resolves the package manager instead of assuming apt.
ARG WEBTOP_BASE_IMAGE=lscr.io/linuxserver/webtop
ARG WEBTOP_BASE_TAG=debian-xfce
FROM ${WEBTOP_BASE_IMAGE}:${WEBTOP_BASE_TAG}

# Versions come from versions.env so Renovate has one file to bump and the
# build is reproducible. Passed as build args by the workflow.
ARG GO_VERSION
ARG NODE_VERSION
ARG UV_VERSION
ARG GOLANGCI_LINT_VERSION
ARG HERDR_VERSION
ARG CODEX_VERSION
ARG CLAUDE_CODE_VERSION
ARG KUBECTL_VERSION
ARG HELM_VERSION
ARG FLUX_VERSION
ARG KUSTOMIZE_VERSION
ARG TALOSCTL_VERSION
ARG SOPS_VERSION
ARG AGE_VERSION
ARG GH_VERSION
ARG YQ_VERSION

COPY install.sh /tmp/install.sh

# One stage per layer: the system packages and language toolchains change far
# less often than the agent CLIs, so a codex bump reuses everything above it.
RUN /tmp/install.sh system
RUN GO_VERSION="${GO_VERSION}" \
    NODE_VERSION="${NODE_VERSION}" \
    UV_VERSION="${UV_VERSION}" \
    GOLANGCI_LINT_VERSION="${GOLANGCI_LINT_VERSION}" \
    /tmp/install.sh langs
RUN KUBECTL_VERSION="${KUBECTL_VERSION}" \
    HELM_VERSION="${HELM_VERSION}" \
    FLUX_VERSION="${FLUX_VERSION}" \
    KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION}" \
    TALOSCTL_VERSION="${TALOSCTL_VERSION}" \
    SOPS_VERSION="${SOPS_VERSION}" \
    AGE_VERSION="${AGE_VERSION}" \
    GH_VERSION="${GH_VERSION}" \
    YQ_VERSION="${YQ_VERSION}" \
    /tmp/install.sh tools
RUN HERDR_VERSION="${HERDR_VERSION}" \
    CODEX_VERSION="${CODEX_VERSION}" \
    CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION}" \
    /tmp/install.sh agents \
 && rm -f /tmp/install.sh

# ENV rather than profile.d: the XFCE session and everything launched from a
# desktop menu are not login shells, so a profile script would miss them.
# corepack resolves pnpm/yarn from each project's packageManager field on first
# use, which is what it is for -- but it prompts before downloading, and an
# interactive prompt in a desktop terminal just looks like a hang.
#
# PATH *prepends* rather than replaces: the base image puts LinuxServer's
# python venv on /lsiopy/bin, which Selkies runs out of. Spelling out a full
# PATH here would drop it and break the desktop.
ENV GOROOT=/opt/go \
    GOTOOLCHAIN=local \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    PATH=/opt/go/bin:/opt/node/bin:${PATH}

# LinuxServer overlay: /custom-cont-init.d scripts run after the built-in init
# and before any service starts. COPY preserves the 0755 bits from git.
COPY root/ /

