#!/usr/bin/env bash
# tools/check-versions.sh — assert that files which must move together do.
#
# Two invariants, both per cluster, so one cluster upgrading never implies
# anything about another:
#
# 1. talconfig vs the tuppr upgrade CRs (Talos/Kubernetes versions).
#    A mismatch means an upgrade touched one file but not the other. tuppr skips
#    nodes listed in status.completedNodes, so the drift stays dormant — until
#    any spec change bumps the CR's generation, which clears that list and makes
#    tuppr roll every node to whatever the CR says. If the CR is behind, that is
#    a downgrade.
#
# 2. CephCluster daemon image vs the rook-ceph toolbox image.
#    Both are the same quay.io/ceph/ceph tag and Renovate moves them in one
#    per-cluster PR. If only one moves, the toolbox runs client code from a
#    different Ceph release than the daemons it administers — which is exactly
#    the tool you reach for mid-upgrade to decide whether the cluster is healthy.
#
# Deliberate mismatches: put '# version-sync: ignore' in the tuppr or toolbox
# file.
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
# Rook-Ceph runs on Ottawa and Robbinsdale only; St. Petersburg has no cluster.
CEPH_CLUSTERS = ["ottawa", "robbinsdale"]
MARKER = "# version-sync: ignore"
PAIRS = [
    ("talosVersion", "talos-upgrade.yaml", "talos"),
    ("kubernetesVersion", "kubernetes-upgrade.yaml", "kubernetes"),
]
CEPH_IMAGE = "quay.io/ceph/ceph:"

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

for cluster in CEPH_CLUSTERS:
    base = pathlib.Path(f"kubernetes/apps/base/rook-ceph/rook-ceph-{cluster}/config")
    clusterfile = base / "cluster.yaml"
    toolboxfile = base / "toolbox.yaml"
    raw = toolboxfile.read_text()

    if MARKER in raw:
        skipped.append(f"{cluster}/toolbox.yaml")
        continue

    want = yaml.safe_load(clusterfile.read_text())["spec"]["cephVersion"]["image"]
    containers = yaml.safe_load(raw)["spec"]["template"]["spec"]["containers"]
    images = [c["image"] for c in containers if c["image"].startswith(CEPH_IMAGE)]

    if not images:
        failures.append(
            f"  {cluster}: {toolboxfile}\n"
            f"    no container running {CEPH_IMAGE}* — cannot verify against\n"
            f"  {clusterfile}\n"
            f"    spec.cephVersion.image: {want}"
        )
        continue

    for got in sorted(set(images)):
        if want != got:
            failures.append(
                f"  {cluster}: {clusterfile}\n"
                f"    spec.cephVersion.image: {want}\n"
                f"  vs {toolboxfile}\n"
                f"    container image: {got}"
            )

for entry in skipped:
    print(f"  skipped (marker): {entry}")

if failures:
    print("✗ version mismatch between files that must move together:\n", file=sys.stderr)
    print("\n\n".join(failures), file=sys.stderr)
    print(
        "\nFix both files, or add '# version-sync: ignore' to the tuppr/toolbox "
        "file if the difference is intentional.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"✓ versions in sync: talos/kubernetes {' '.join(CLUSTERS)}"
    f" | ceph {' '.join(CEPH_CLUSTERS)}"
)
PY
