# shellcheck shell=bash
if ! python3 -c "import yaml" 2>/dev/null; then
  _yaml_site=$(find /workspace/.local/share/nix/root/nix/store -maxdepth 1 -name "*pyyaml*" -not -name "*.drv" -type d 2>/dev/null | head -1 || true)
  if [ -n "$_yaml_site" ]; then
    export PYTHONPATH="${_yaml_site}/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  elif command -v uv >/dev/null 2>&1; then
    PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/bin" && pwd):$PATH"
    export PATH
  else
    echo "${0##*/}: python3 has no PyYAML and uv is not installed (brew install uv)" >&2
    exit 1
  fi
fi
