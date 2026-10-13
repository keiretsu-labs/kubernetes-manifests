#!/usr/bin/env bash
# tools/orphans.sh — kustomization <-> disk drift detector for kubernetes/apps.
# Reports two discrepancy classes, prints nothing else unless progress is enabled:
#   MISSING   a resources/components/crds/bases/patch entry points at a local
#             target that does not exist (would break the render)
#   UNLISTED  a YAML file sits next to a kustomization.yaml that never names it
#             (plausibly dead / left behind by a decommission)
# Remote URLs (http, git::, oci, github.com, ?ref=) and generated files
# (*.dec, *.bak, *.tmp) are ignored to avoid false positives.
#
# Exit 0 = clean, 1 = discrepancies found, 2 = bad usage.
#
# Usage:
#   tools/orphans.sh            # scan kubernetes/apps
#   tools/orphans.sh <dir>      # scan an arbitrary tree (used by tests)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tools/orphans.py" "${1:-$ROOT/kubernetes/apps}"
