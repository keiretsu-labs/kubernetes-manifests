#!/usr/bin/env bash
# tools/flate.sh — run the exact Flate release pinned by CI.
#
# A matching system binary is used as-is. Otherwise the release archive is
# downloaded once into the user cache, checksum-verified, and reused. This
# keeps local/Codex renders on the same Flate build as GitHub Actions without
# requiring every workspace image to update in lockstep.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/flate.yaml"

pins="$(
  sed -n 's|.*home-operations/flate/action@v\([0-9][0-9.]*\).*|\1|p' "$WORKFLOW" \
    | sort -u
)"
if [ -z "$pins" ] || [ "$(printf '%s\n' "$pins" | wc -l | tr -d ' ')" != 1 ]; then
  echo "error: expected exactly one Flate action version in $WORKFLOW; found: ${pins:-none}" >&2
  exit 2
fi
version="$pins"

# SOPS-encrypted Secret values are intentionally unavailable in offline renders.
# Without this flag, GitRepository reconciliation can fail before Flate reaches
# the manifests being compared (and diff can fail identically on both trees).
# Keep every test/diff caller safe, including CI invocations outside Make.
flate_args=("$@")
case "${flate_args[0]:-}" in
  test|diff)
    allow_missing_secrets=false
    for arg in "${flate_args[@]}"; do
      if [ "$arg" = "--allow-missing-secrets" ]; then
        allow_missing_secrets=true
        break
      fi
    done
    if [ "$allow_missing_secrets" = false ]; then
      flate_args+=(--allow-missing-secrets)
    fi
    ;;
esac

# Flate releases are UPX-packed. The self-extraction stub walks argv/envp/auxv
# and, once that block grows past what it assumes, jumps into the environment
# strings themselves — a segfault with error 15 (instruction fetch from a
# writable page) and an ip inside the env block. Agent workspaces inject
# hundreds of variables and cross that line, which makes the binary look
# broken: every `flate --version` probe below returns nothing, so a
# correctly-downloaded release is rejected as "does not report Flate <v>".
#
# So run flate with only the variables it needs. Small environments (CI, a
# normal shell) are left completely alone, so this cannot change how CI
# behaves. Set KMAN_FLATE_KEEP_ENV=1 to disable the pruning entirely.
flate_env=()
if [ -z "${KMAN_FLATE_KEEP_ENV:-}" ]; then
  env_count=$(env | wc -l | tr -d ' ')
  env_bytes=$(env | wc -c | tr -d ' ')
  if [ "$env_count" -gt 192 ] || [ "$env_bytes" -gt 24576 ]; then
    for _v in PATH HOME TMPDIR TMP TEMP USER LOGNAME LANG LC_ALL TERM \
              SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE GIT_SSL_CAINFO \
              NIX_SSL_CERT_FILE XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME \
              DOCKER_CONFIG GNUPGHOME \
              HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy \
              GITHUB_TOKEN GH_TOKEN; do
      [ -n "${!_v+x}" ] && flate_env+=("$_v=${!_v}")
    done
    # Anything the caller set for flate, SOPS or this repo's own helpers.
    while IFS= read -r _v; do
      [ -n "${!_v+x}" ] && flate_env+=("$_v=${!_v}")
    done < <(compgen -v | grep -E '^(FLATE_|SOPS_|KMAN_)' || true)
    unset _v
  fi
fi

# Run flate, pruning the environment when it is large enough to break the stub.
run_flate() {
  local bin="$1"; shift
  if [ "${#flate_env[@]}" -eq 0 ]; then
    exec "$bin" "$@"
  fi
  exec env -i "${flate_env[@]}" "$bin" "$@"
}

flate_version() {
  if [ "${#flate_env[@]}" -eq 0 ]; then
    "$1" --version 2>/dev/null | sed -n 's/^flate version //p' | head -1
  else
    env -i "${flate_env[@]}" "$1" --version 2>/dev/null \
      | sed -n 's/^flate version //p' | head -1
  fi
}

if [ -n "${KMAN_FLATE_BIN:-}" ]; then
  actual="$(flate_version "$KMAN_FLATE_BIN" || true)"
  if [ "$actual" != "$version" ]; then
    echo "error: KMAN_FLATE_BIN is Flate ${actual:-unknown}; CI requires $version" >&2
    exit 2
  fi
  run_flate "$KMAN_FLATE_BIN" "${flate_args[@]}"
fi

if command -v flate >/dev/null 2>&1; then
  system_flate="$(command -v flate)"
  if [ "$(flate_version "$system_flate" || true)" = "$version" ]; then
    run_flate "$system_flate" "${flate_args[@]}"
  fi
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$os/$arch" in
  darwin/x86_64) platform="darwin_amd64" ;;
  darwin/arm64)  platform="darwin_arm64" ;;
  linux/x86_64) platform="linux_amd64" ;;
  linux/aarch64|linux/arm64) platform="linux_arm64" ;;
  *)
    echo "error: no bootstrapped Flate binary for $os/$arch" >&2
    exit 2
    ;;
esac

if [ -n "${XDG_CACHE_HOME:-}" ]; then
  cache_root="$XDG_CACHE_HOME"
elif [ "$os" = darwin ]; then
  cache_root="${HOME:?HOME is required}/Library/Caches"
else
  cache_root="${HOME:?HOME is required}/.cache"
fi

install_dir="$cache_root/kubernetes-manifests/flate/$version/$platform"
cached_flate="$install_dir/flate"
if [ -x "$cached_flate" ] && [ "$(flate_version "$cached_flate" || true)" = "$version" ]; then
  run_flate "$cached_flate" "${flate_args[@]}"
fi

mkdir -p "$install_dir"
stage="$(mktemp -d "$install_dir/.install.XXXXXX")"
cleanup() {
  rm -rf -- "$stage"
}
trap cleanup EXIT INT TERM

asset="flate_${version}_${platform}.tar.gz"
url="https://github.com/home-operations/flate/releases/download/v${version}/${asset}"
curl_flags=(--fail --silent --show-error --location --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120)
curl "${curl_flags[@]}" "$url" -o "$stage/$asset"
curl "${curl_flags[@]}" "$url.sha256" -o "$stage/$asset.sha256"

expected="$(tr -d '[:space:]' <"$stage/$asset.sha256")"
case "$expected" in
  *[!0-9a-fA-F]*|"")
    echo "error: invalid SHA-256 published for $asset" >&2
    exit 1
    ;;
esac
if [ "${#expected}" != 64 ]; then
  echo "error: invalid SHA-256 length published for $asset" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$stage/$asset" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$stage/$asset" | awk '{print $1}')"
fi
if [ "$actual" != "$expected" ]; then
  echo "error: checksum mismatch for $asset" >&2
  exit 1
fi

tar -xzf "$stage/$asset" -C "$stage" flate
chmod 0755 "$stage/flate"
if [ "$(flate_version "$stage/flate")" != "$version" ]; then
  echo "error: downloaded $asset does not report Flate $version" >&2
  exit 1
fi

# Same verified bytes may race here in parallel sessions; rename keeps readers
# from ever observing a partial executable.
mv -f -- "$stage/flate" "$cached_flate"
cleanup
trap - EXIT INT TERM
run_flate "$cached_flate" "${flate_args[@]}"
