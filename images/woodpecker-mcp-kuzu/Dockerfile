FROM python:3.12-slim

# kubectl - required by the Kubernetes topology connector (WP_TOPOLOGY=k8s).
# In a pod it uses the in-cluster ServiceAccount automatically (empty context).
# docker CLI (client only) - required by the Docker topology connector
# (WP_TOPOLOGY=docker); only useful with the opt-in socket mount, see
# docker-compose.yml's `http` profile.
# Both downloads are sha256-verified (kubectl against its published .sha256;
# the docker tgz against checksums pinned here, computed from the release).
ARG KUBECTL_VERSION=v1.30.5
ARG DOCKER_CLI_VERSION=27.3.1
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && ARCH=$(dpkg --print-architecture) \
 && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256")  /usr/local/bin/kubectl" | sha256sum -c - \
 && chmod +x /usr/local/bin/kubectl \
 && case "$ARCH" in \
      amd64) DARCH=x86_64; DSHA=9b4f6fe406e50f9085ee474c451e2bb5adb119a03591f467922d3b4e2ddf31d3 ;; \
      arm64) DARCH=aarch64; DSHA=4da6a6c7502b7ab561675a5ff5ac192d9b49d76d0b8847cf17ade246122279f4 ;; \
      *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/docker.tgz "https://download.docker.com/linux/static/stable/${DARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
 && echo "${DSHA}  /tmp/docker.tgz" | sha256sum -c - \
 && tar -xz --strip-components=1 -C /usr/local/bin -f /tmp/docker.tgz docker/docker \
 && rm /tmp/docker.tgz \
 && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml README.md ./
COPY woodpecker_mcp ./woodpecker_mcp
# Install with the [kuzu] extra: embedded graph DB backend (WP_GRAPH_BACKEND=kuzu).
# Kuzu is pinned to 0.11.3 (final upstream release); python:3.12-slim ships
# libstdc++ so the kuzu native extension resolves at import time.
RUN pip install --no-cache-dir ".[kuzu]"

# Graph DB persists here; mount a volume to keep it across restarts.
ENV WP_KUZU_PATH=/data/woodpecker.kuzu \
    WP_HTTP_HOST=0.0.0.0

RUN mkdir -p /data && useradd -u 10001 wp && chown -R wp /data
USER wp

EXPOSE 8000
ENTRYPOINT ["woodpecker-mcp"]
CMD ["serve", "--http", "--port", "8000"]
