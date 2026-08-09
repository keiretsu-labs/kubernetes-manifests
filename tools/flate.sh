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

flate_version() {
  "$1" --version 2>/dev/null | sed -n 's/^flate version //p' | head -1
}

if [ -n "${KMAN_FLATE_BIN:-}" ]; then
  actual="$(flate_version "$KMAN_FLATE_BIN" || true)"
  if [ "$actual" != "$version" ]; then
    echo "error: KMAN_FLATE_BIN is Flate ${actual:-unknown}; CI requires $version" >&2
    exit 2
  fi
  exec "$KMAN_FLATE_BIN" "${flate_args[@]}"
fi

if command -v flate >/dev/null 2>&1; then
  system_flate="$(command -v flate)"
  if [ "$(flate_version "$system_flate" || true)" = "$version" ]; then
    exec "$system_flate" "${flate_args[@]}"
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
  exec "$cached_flate" "${flate_args[@]}"
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
exec "$cached_flate" "${flate_args[@]}"
