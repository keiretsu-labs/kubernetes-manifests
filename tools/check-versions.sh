#!/usr/bin/env bash
# tools/check-versions.sh — assert that files which must move together do.
#
# Three invariants, all per cluster, so one cluster upgrading never implies
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
# 3. CephCluster daemon image vs what the deployed Rook operator will run.
#    Rook refuses any Ceph major absent from the supportedVersions list compiled
#    into the operator, and refuses non-stable releases, unless
#    allowUnsupported is true. It fails the version check before it populates
#    cluster info, so the operator never finishes initializing: no mon failover,
#    no OSD lifecycle, no reconcile of anything, and the CephFilesystem
#    controller respawns a detect-version job every ~10s forever. The daemons
#    are left untouched at their old release, so nothing looks broken until you
#    read the CephCluster status. Both inputs are in git, and Rook's supported
#    list is readable at the operator's own tag, so this is checkable here
#    rather than discovered in production. Ceph puts the release type in the
#    minor field (x.0.z development, x.1.z release candidate, x.2.z stable), so
#    an RC has no prerelease suffix for Renovate to filter on: v21.1.0 shipped
#    to both clusters as a routine major bump.
#
# Deliberate mismatches: put '# version-sync: ignore' in the tuppr, toolbox, or
# CephCluster file.
#
# Usage:
#   tools/check-versions.sh
set -euo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY'
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

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
ROOK_SRC = (
    "https://raw.githubusercontent.com/rook/rook/{tag}"
    "/pkg/operator/ceph/version/version.go"
)
# Ceph release type lives in the minor field; x.2.z is the stable line.
CEPH_STABLE_MINOR = 2

failures = []
skipped = []
rook_verified = []

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

for cluster in CEPH_CLUSTERS:
    base = pathlib.Path(f"kubernetes/apps/base/rook-ceph/rook-ceph-{cluster}")
    clusterfile = base / "config" / "cluster.yaml"
    hrfile = base / "app" / "helmrelease.yaml"
    raw = clusterfile.read_text()

    if MARKER in raw:
        skipped.append(f"{cluster}/cluster.yaml")
        continue

    cephspec = yaml.safe_load(raw)["spec"]["cephVersion"]
    image = cephspec["image"]

    if cephspec.get("allowUnsupported"):
        skipped.append(f"{cluster}/cluster.yaml (allowUnsupported: true)")
        continue

    parsed = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", image.split(":", 1)[-1])
    if not parsed:
        failures.append(
            f"  {cluster}: {clusterfile}\n"
            f"    spec.cephVersion.image: {image}\n"
            f"    tag is not a vX.Y.Z release — cannot check it against Rook"
        )
        continue
    major, minor = int(parsed[1]), int(parsed[2])

    if minor != CEPH_STABLE_MINOR:
        kind = "development build" if minor == 0 else "release candidate"
        failures.append(
            f"  {cluster}: {clusterfile}\n"
            f"    spec.cephVersion.image: {image}\n"
            f"    {major}.{minor}.z is a Ceph {kind}, not a stable release.\n"
            f"    Stable Ceph is x.{CEPH_STABLE_MINOR}.z — see\n"
            f"    https://docs.ceph.com/en/latest/releases/general/"
        )
        continue

    rook_tag = yaml.safe_load(hrfile.read_text())["spec"]["chart"]["spec"]["version"]
    if not rook_tag.startswith("v"):
        rook_tag = f"v{rook_tag}"
    url = ROOK_SRC.format(tag=rook_tag)

    try:
        with urllib.request.urlopen(url, timeout=20) as resp:
            src = resp.read().decode()
    except (urllib.error.URLError, OSError) as err:
        note = f"{cluster}/cluster.yaml (could not read {url}: {err})"
        if os.environ.get("CI"):
            failures.append(f"  {note}")
        else:
            skipped.append(f"{note} — offline, Rook support NOT verified")
        continue

    majors = {
        name: int(num)
        for name, num in re.findall(r"(\w+)\s*=\s*CephVersion\{(\d+),", src)
    }
    listed = re.search(r"supportedVersions\s*=\s*\[\]CephVersion\{([^}]*)\}", src)
    supported = sorted(
        {majors[n] for n in (n.strip() for n in listed[1].split(",")) if n in majors}
    ) if listed else []

    if not supported:
        failures.append(f"  {cluster}: could not parse supportedVersions from {url}")
        continue

    if major in supported:
        rook_verified.append(cluster)
    else:
        failures.append(
            f"  {cluster}: {clusterfile}\n"
            f"    spec.cephVersion.image: {image}  (Ceph major {major})\n"
            f"  vs {hrfile}\n"
            f"    spec.chart.spec.version: {rook_tag}\n"
            f"    that Rook release supports Ceph majors {supported}\n"
            f"    Rook fails its version check before initializing and stops\n"
            f"    reconciling this cluster entirely. Upgrade Rook first."
        )

for entry in skipped:
    print(f"  skipped (marker): {entry}")

if failures:
    print("✗ version mismatch between files that must move together:\n", file=sys.stderr)
    print("\n\n".join(failures), file=sys.stderr)
    print(
        "\nFix both files, or add '# version-sync: ignore' to the tuppr, toolbox, "
        "or CephCluster file if the difference is intentional.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"✓ versions in sync: talos/kubernetes {' '.join(CLUSTERS)}"
    f" | ceph {' '.join(CEPH_CLUSTERS)}"
    f" | ceph supported by deployed rook"
    f" {' '.join(rook_verified) if rook_verified else '(none verified)'}"
)
PY
