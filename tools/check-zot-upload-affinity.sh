#!/usr/bin/env bash
# Assert the GitOps contract that makes resumable OCI uploads safe with Zot HA.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT"

if ! python3 -c "import yaml" 2>/dev/null; then
  yaml_site="$(find /workspace/.local/share/nix/root/nix/store -maxdepth 1 -name "*pyyaml*" -not -name "*.drv" -type d 2>/dev/null | head -1)"
  if [ -n "$yaml_site" ]; then
    export PYTHONPATH="$yaml_site/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  fi
fi

python3 - <<'PY'
import pathlib
import sys

import yaml

path = pathlib.Path("kubernetes/apps/base/zot/zot/helmrelease.yaml")
release = yaml.safe_load(path.read_text())
values = release.get("spec", {}).get("values", {})
if values.get("replicaCount", 1) < 2:
    raise SystemExit("Zot upload-affinity guard expects the highly available replica count")

for renderer in release.get("spec", {}).get("postRenderers", []):
    for patch in renderer.get("kustomize", {}).get("patches", []):
        target = patch.get("target", {})
        if target.get("kind") != "Service" or target.get("name") != "zot":
            continue
        operations = yaml.safe_load(patch.get("patch", ""))
        if not isinstance(operations, list):
            continue
        affinity = next(
            (
                operation
                for operation in operations
                if operation.get("op") in {"add", "replace"}
                and operation.get("path") == "/spec/sessionAffinity"
                and operation.get("value") == "ClientIP"
            ),
            None,
        )
        affinity_config = next(
            (
                operation
                for operation in operations
                if operation.get("op") in {"add", "replace"}
                and operation.get("path") == "/spec/sessionAffinityConfig"
                and operation.get("value", {})
                .get("clientIP", {})
                .get("timeoutSeconds") == 10800
            ),
            None,
        )
        if affinity and affinity_config:
            print("✓ zot resumable-upload affinity contract")
            sys.exit(0)

raise SystemExit(
    "Zot must post-render its Service with ClientIP affinity and a 10800-second "
    "upload-session timeout"
)
PY
