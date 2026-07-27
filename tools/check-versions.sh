#!/usr/bin/env bash
# tools/check-versions.sh — assert each cluster's talconfig and tuppr upgrade CRs
# declare the same Talos/Kubernetes versions.
#
# A mismatch means an upgrade touched one file but not the other. tuppr skips
# nodes listed in status.completedNodes, so the drift stays dormant — until any
# spec change bumps the CR's generation, which clears that list and makes tuppr
# roll every node to whatever the CR says. If the CR is behind, that is a
# downgrade.
#
# Deliberate mismatches: put '# version-sync: ignore' in the tuppr file.
#
# Usage:
#   tools/check-versions.sh
set -euo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY'
import pathlib
import sys

import yaml

CLUSTERS = ["ottawa", "robbinsdale", "stpetersburg"]
MARKER = "# version-sync: ignore"
PAIRS = [
    ("talosVersion", "talos-upgrade.yaml", "talos"),
    ("kubernetesVersion", "kubernetes-upgrade.yaml", "kubernetes"),
]

failures = []
skipped = []

for cluster in CLUSTERS:
    talconfig = pathlib.Path(f"clusters/talos-{cluster}/bootstrap/talos/talconfig.yaml")
    declared = yaml.safe_load(talconfig.read_text())

    for talkey, filename, speckey in PAIRS:
        crfile = pathlib.Path(
            f"kubernetes/apps/base/tuppr/tuppr-config-{cluster}/config/{filename}"
        )
        raw = crfile.read_text()

        if MARKER in raw:
            skipped.append(f"{cluster}/{filename}")
            continue

        want = declared[talkey]
        got = yaml.safe_load(raw)["spec"][speckey]["version"]
        if want != got:
            failures.append(
                f"  {cluster}: {talconfig}\n"
                f"    {talkey}: {want}\n"
                f"  vs {crfile}\n"
                f"    spec.{speckey}.version: {got}"
            )

for entry in skipped:
    print(f"  skipped (marker): {entry}")

if failures:
    print("✗ talconfig / tuppr version mismatch:\n", file=sys.stderr)
    print("\n\n".join(failures), file=sys.stderr)
    print(
        "\nFix both files, or add '# version-sync: ignore' to the tuppr file if "
        "the difference is intentional.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"✓ versions in sync: {' '.join(CLUSTERS)}")
PY
