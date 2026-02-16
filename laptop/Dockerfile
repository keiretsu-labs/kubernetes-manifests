# syntax=docker/dockerfile:1

# Tool versions — bump these to update (or use Renovate)
ARG KUBECTL_V=v1.35.1
ARG FLUX_V=v2.7.5
ARG HELM_V=v4.1.1
ARG KUSTOMIZE_V=v5.8.1
ARG YQ_V=v4.52.2
ARG SOPS_V=v3.11.0
ARG JQ_V=jq-1.8.1
ARG GH_V=2.86.0

# Stage 1: download tools (each RUN = cached layer)
FROM debian:bookworm-slim AS tools

ARG TARGETARCH
ARG KUBECTL_V FLUX_V HELM_V KUSTOMIZE_V YQ_V SOPS_V JQ_V GH_V

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tools

RUN curl -fsSL --retry 5 --retry-delay 2 -o kubectl \
      "https://dl.k8s.io/release/${KUBECTL_V}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x kubectl

RUN curl -fsSL --retry 5 --retry-delay 2 \
      "https://github.com/fluxcd/flux2/releases/download/${FLUX_V}/flux_${FLUX_V#v}_linux_${TARGETARCH}.tar.gz" \
    | tar xz flux

RUN curl -fsSL --retry 5 --retry-delay 2 \
      "https://get.helm.sh/helm-${HELM_V}-linux-${TARGETARCH}.tar.gz" \
    | tar xz --strip-components=1 "linux-${TARGETARCH}/helm"

RUN curl -fsSL --retry 5 --retry-delay 2 \
      "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_V}/kustomize_${KUSTOMIZE_V}_linux_${TARGETARCH}.tar.gz" \
    | tar xz kustomize

RUN curl -fsSL --retry 5 --retry-delay 2 -o yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_V}/yq_linux_${TARGETARCH}" \
    && chmod +x yq

RUN curl -fsSL --retry 5 --retry-delay 2 -o sops \
      "https://github.com/getsops/sops/releases/download/${SOPS_V}/sops-${SOPS_V}.linux.${TARGETARCH}" \
    && chmod +x sops

RUN curl -fsSL --retry 5 --retry-delay 2 -o jq \
      "https://github.com/jqlang/jq/releases/download/${JQ_V}/jq-linux-${TARGETARCH}" \
    && chmod +x jq

RUN curl -fsSL --retry 5 --retry-delay 2 \
      "https://github.com/cli/cli/releases/download/v${GH_V}/gh_${GH_V}_linux_${TARGETARCH}.tar.gz" \
    | tar xz --strip-components=2 "gh_${GH_V}_linux_${TARGETARCH}/bin/gh"

# Stage 2: final image — coder/code-server (Fedora 39, user=coder, port=8080)
FROM ghcr.io/coder/code-server:4.109.2-39

USER root

COPY --from=tools /tools/ /usr/local/bin/

RUN dnf install -y nodejs npm \
    && dnf clean all \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force \
    && chsh -s /usr/bin/zsh coder

USER 1000
