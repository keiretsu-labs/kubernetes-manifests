#!/usr/bin/env bash
# tools/check-velero-pvc-coverage.sh — repo-side contract: every namespace that
# declares durable volume intent in Git must have a Kopiur SnapshotPolicy on
# that cluster, or a committed exemption. Filename kept so CI/make still call
# it; the oracle is SnapshotPolicy, not Velero Schedule.
#
# See kubernetes/apps/base/kopiur/pvc-policy-exemptions.yaml.
set -euo pipefail
cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! python3 -c "import yaml" 2>/dev/null; then
  _yaml_site=$(find /workspace/.local/share/nix/root/nix/store -maxdepth 1 -name "*pyyaml*" -not -name "*.drv" -type d 2>/dev/null | head -1)
  if [ -n "$_yaml_site" ]; then
    export PYTHONPATH="${_yaml_site}/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  fi
fi

python3 - <<'PY'
from __future__ import annotations

from pathlib import Path
import sys

import yaml

ROOT = Path.cwd()
CLUSTERS = ("ottawa", "robbinsdale", "stpetersburg")
EXEMPTIONS_PATH = ROOT / "kubernetes/apps/base/kopiur/pvc-policy-exemptions.yaml"
POLICY_PATHS = {
    "ottawa": (ROOT / "kubernetes/apps/base/kopiur/kopiur-ottawa-policies",),
    "robbinsdale": (ROOT / "kubernetes/apps/base/kopiur/kopiur-robbinsdale-policies",),
    "stpetersburg": (
        ROOT / "kubernetes/apps/base/home-assistant/home-assistant/kopiur",
    ),
}


def load_docs(path: Path):
    try:
        text = path.read_text()
    except OSError as err:
        raise SystemExit(f"cannot read {path}: {err}") from err
    try:
        for doc in yaml.safe_load_all(text):
            if isinstance(doc, dict):
                yield doc
    except yaml.YAMLError as err:
        raise SystemExit(f"cannot parse {path}: {err}") from err


def is_flux_kustomization(doc: dict) -> bool:
    return (
        doc.get("kind") == "Kustomization"
        and str(doc.get("apiVersion", "")).startswith("kustomize.toolkit.fluxcd.io/")
    )


def is_snapshot_policy(doc: dict) -> bool:
    return (
        doc.get("kind") == "SnapshotPolicy"
        and "kopiur.home-operations.com" in str(doc.get("apiVersion", ""))
    )


def normalize_repo_path(path: str) -> Path:
    if path.startswith("./"):
        path = path[2:]
    return ROOT / path


def path_declares_durable_volume(path: Path) -> bool:
    """True when Git under the Flux path declares a PVC, VCT, or CNPG storage."""
    if not path.exists():
        return False
    files = list(path.rglob("*.yaml")) + list(path.rglob("*.yml"))
    for file_path in files:
        for doc in load_docs(file_path):
            kind = doc.get("kind")
            if kind == "PersistentVolumeClaim":
                return True
            spec = doc.get("spec")
            if isinstance(spec, dict) and spec.get("volumeClaimTemplates"):
                return True
            if (
                kind == "Cluster"
                and str(doc.get("apiVersion", "")).startswith("postgresql.cnpg.io/")
            ):
                storage = spec.get("storage") if isinstance(spec, dict) else None
                wal = spec.get("walStorage") if isinstance(spec, dict) else None
                if isinstance(storage, dict) and storage.get("size"):
                    return True
                if isinstance(wal, dict) and wal.get("size"):
                    return True
    return False


def policy_namespaces(cluster: str) -> set[str]:
    covered: set[str] = set()
    for policy_dir in POLICY_PATHS[cluster]:
        if not policy_dir.is_dir():
            continue
        files = list(policy_dir.glob("*.yaml")) + list(policy_dir.glob("*.yml"))
        for path in files:
            for doc in load_docs(path):
                if not is_snapshot_policy(doc):
                    continue
                ns = (doc.get("metadata") or {}).get("namespace")
                if isinstance(ns, str) and ns:
                    covered.add(ns)
    return covered


def pvc_namespaces(cluster: str) -> set[str]:
    found: set[str] = set()
    cluster_root = ROOT / f"kubernetes/apps/{cluster}"
    for path in cluster_root.rglob("*.yaml"):
        for doc in load_docs(path):
            if not is_flux_kustomization(doc):
                continue
            spec = doc.get("spec") or {}
            target = spec.get("targetNamespace")
            source_path = spec.get("path")
            if not isinstance(target, str) or not target:
                continue
            if not isinstance(source_path, str) or not source_path:
                continue
            if path_declares_durable_volume(normalize_repo_path(source_path)):
                found.add(target)
    return found


def load_exemptions() -> dict[str, dict[str, str]]:
    """cluster -> {namespace: reason}."""
    if not EXEMPTIONS_PATH.is_file():
        raise SystemExit(f"missing exemption list: {EXEMPTIONS_PATH}")
    docs = list(load_docs(EXEMPTIONS_PATH))
    if not docs:
        raise SystemExit(f"empty exemption list: {EXEMPTIONS_PATH}")
    doc = docs[0]
    if doc.get("kind") != "KopiurPVCPolicyExemptions":
        raise SystemExit(
            f"{EXEMPTIONS_PATH}: expected kind KopiurPVCPolicyExemptions, "
            f"got {doc.get('kind')!r}"
        )
    raw = doc.get("exemptions")
    if not isinstance(raw, list) or not raw:
        raise SystemExit(f"{EXEMPTIONS_PATH}: exemptions must be a non-empty list")

    out: dict[str, dict[str, str]] = {c: {} for c in CLUSTERS}
    for idx, entry in enumerate(raw):
        if not isinstance(entry, dict):
            raise SystemExit(f"{EXEMPTIONS_PATH}: exemptions[{idx}] must be a mapping")
        cluster = entry.get("cluster")
        namespace = entry.get("namespace")
        reason = entry.get("reason")
        if cluster not in CLUSTERS:
            raise SystemExit(
                f"{EXEMPTIONS_PATH}: exemptions[{idx}].cluster must be one of {CLUSTERS}"
            )
        if not isinstance(namespace, str) or not namespace:
            raise SystemExit(f"{EXEMPTIONS_PATH}: exemptions[{idx}].namespace required")
        if not isinstance(reason, str) or not reason.strip():
            raise SystemExit(
                f"{EXEMPTIONS_PATH}: exemptions[{idx}] ({cluster}/{namespace}) "
                "needs a non-empty reason"
            )
        if namespace in out[cluster]:
            raise SystemExit(
                f"{EXEMPTIONS_PATH}: duplicate exemption {cluster}/{namespace}"
            )
        out[cluster][namespace] = " ".join(reason.split())
    return out


def main() -> int:
    exemptions = load_exemptions()
    failures: list[str] = []
    stale: list[str] = []

    for cluster in CLUSTERS:
        pvc_ns = pvc_namespaces(cluster)
        covered = policy_namespaces(cluster)
        exempt = exemptions[cluster]

        for namespace in sorted(pvc_ns - covered - set(exempt)):
            failures.append(
                f"{cluster}/{namespace}: declares a PVC/VCT/CNPG volume in Git "
                f"but has no Kopiur SnapshotPolicy and no exemption"
            )

        for namespace in sorted(set(exempt) - pvc_ns):
            stale.append(
                f"{cluster}/{namespace}: exemption has no matching Git-declared "
                f"PVC namespace on this cluster (remove or fix the entry)"
            )
        for namespace in sorted(set(exempt) & covered):
            stale.append(
                f"{cluster}/{namespace}: exempted but also has a SnapshotPolicy "
                f"(drop the exemption or the policy)"
            )

    if failures or stale:
        print("kopiur PVC policy coverage check failed:", file=sys.stderr)
        for line in failures + stale:
            print(f"  {line}", file=sys.stderr)
        if failures:
            print(
                "  add a SnapshotPolicy for the namespace, or document the "
                "decision in "
                "kubernetes/apps/base/kopiur/pvc-policy-exemptions.yaml",
                file=sys.stderr,
            )
        return 1

    covered_total = sum(len(policy_namespaces(c)) for c in CLUSTERS)
    exempt_total = sum(len(exemptions[c]) for c in CLUSTERS)
    print(
        f"✓ kopiur PVC policy coverage "
        f"(policies cover {covered_total} namespaces; {exempt_total} documented exemptions)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
