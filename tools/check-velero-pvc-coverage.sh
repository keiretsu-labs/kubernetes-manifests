#!/usr/bin/env bash
# tools/check-velero-pvc-coverage.sh — repo-side contract: every namespace that
# declares durable volume intent in Git must have a Kopiur SnapshotPolicy on
# that cluster, or a committed exemption. Filename kept so CI/make still call
# it; the oracle is SnapshotPolicy, not Velero Schedule. Git-declared
# local-path PVCs (rancher.io/local-path hostPath) additionally require an
# explicit Kopiur copyMethod: Direct — CSI Snapshot cannot capture them
# (km#2877 / corp/bhaiya#695).
#
# See kubernetes/apps/base/kopiur/pvc-policy-exemptions.yaml. The gate
# treats PVC, VCT, CNPG storage, GarageCluster storage, Grafana PVC, Helm
# persistence, and workload claimName as durable volume intent.
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


def walk_mappings(obj):
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from walk_mappings(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from walk_mappings(value)


def mapping_enables_volume(block) -> bool:
    """True for a Helm persistence/persistentVolume mapping that creates a PVC."""
    if not isinstance(block, dict):
        return False
    if block.get("enabled") is False:
        return False
    if block.get("enabled") is True:
        return True
    return bool(
        block.get("size")
        or block.get("storageClass")
        or block.get("storageClassName")
        or block.get("existingClaim")
    )


def helm_values_declare_volume(values) -> bool:
    if not isinstance(values, dict):
        return False
    for node in walk_mappings(values):
        if mapping_enables_volume(node.get("persistentVolume")):
            return True
        if mapping_enables_volume(node.get("persistence")):
            return True
        if node.get("volumeClaimTemplate") or node.get("volumeClaimTemplates"):
            return True
    return False


def path_declares_durable_volume(path: Path) -> bool:
    """True when Git under the Flux path declares durable volume intent."""
    if not path.exists():
        return False
    files = list(path.rglob("*.yaml")) + list(path.rglob("*.yml"))
    for file_path in files:
        for doc in load_docs(file_path):
            kind = doc.get("kind")
            spec = doc.get("spec") if isinstance(doc.get("spec"), dict) else {}
            if kind == "PersistentVolumeClaim":
                return True
            if spec.get("volumeClaimTemplates"):
                return True
            if (
                kind == "Cluster"
                and str(doc.get("apiVersion", "")).startswith("postgresql.cnpg.io/")
            ):
                storage = spec.get("storage")
                wal = spec.get("walStorage")
                if isinstance(storage, dict) and storage.get("size"):
                    return True
                if isinstance(wal, dict) and wal.get("size"):
                    return True
            if kind == "GarageCluster":
                storage = spec.get("storage")
                if isinstance(storage, dict):
                    for key in ("metadata", "data"):
                        block = storage.get(key)
                        if isinstance(block, dict) and block.get("size"):
                            return True
            if kind == "Grafana" and spec.get("persistentVolumeClaim"):
                return True
            if kind == "HelmRelease" and helm_values_declare_volume(spec.get("values")):
                return True
            if kind in ("Deployment", "StatefulSet", "DaemonSet"):
                for node in walk_mappings(doc):
                    claim = node.get("persistentVolumeClaim")
                    if isinstance(claim, dict) and claim.get("claimName"):
                        return True
    return False


def multi_source_policies() -> list[str]:
    """Kopiur groupBy:None still kopia-ids only the first PVC; ban multi-source."""
    bad: list[str] = []
    for cluster, paths in POLICY_PATHS.items():
        for policy_dir in paths:
            if not policy_dir.is_dir():
                continue
            for path in list(policy_dir.glob("*.yaml")) + list(policy_dir.glob("*.yml")):
                for doc in load_docs(path):
                    if not is_snapshot_policy(doc):
                        continue
                    sources = (doc.get("spec") or {}).get("sources") or []
                    names = []
                    for src in sources:
                        if not isinstance(src, dict):
                            continue
                        pvc = src.get("pvc") or {}
                        if isinstance(pvc, dict) and pvc.get("name"):
                            names.append(pvc["name"])
                    if len(names) > 1:
                        meta = doc.get("metadata") or {}
                        bad.append(
                            f"{cluster}/{meta.get('namespace')}/{meta.get('name')} "
                            f"lists {len(names)} PVCs {names}; split to one policy per PVC"
                        )
    return bad


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


def is_local_path_storage(cluster: str, storage_class) -> bool:
    """rancher.io/local-path (and SP cluster default, which is local-path)."""
    if storage_class == "local-path":
        return True
    if cluster == "stpetersburg" and not storage_class:
        return True
    if (
        cluster == "stpetersburg"
        and isinstance(storage_class, str)
        and "STORAGECLASS" in storage_class
    ):
        return True
    return False


def local_path_pvcs(cluster: str) -> list[tuple[str, str]]:
    """(namespace, pvc name) for Git-declared local-path PVCs on a cluster."""
    found: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
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
            src = normalize_repo_path(source_path)
            if not src.exists():
                continue
            files = list(src.rglob("*.yaml")) + list(src.rglob("*.yml"))
            for file_path in files:
                try:
                    text = file_path.read_text()
                except OSError:
                    continue
                if "PersistentVolumeClaim" not in text:
                    continue
                try:
                    volumes = list(load_docs(file_path))
                except SystemExit:
                    # Non-Kubernetes YAML (e.g. configarr !secret) is not a PVC.
                    continue
                for vol in volumes:
                    if vol.get("kind") != "PersistentVolumeClaim":
                        continue
                    name = (vol.get("metadata") or {}).get("name")
                    if not isinstance(name, str) or not name:
                        continue
                    sc = (vol.get("spec") or {}).get("storageClassName")
                    if not is_local_path_storage(cluster, sc):
                        continue
                    key = (target, name)
                    if key in seen:
                        continue
                    seen.add(key)
                    found.append(key)
    return found


def policy_pvc_copy_methods(cluster: str) -> dict[tuple[str, str], set[str]]:
    """(namespace, pvc name) -> copyMethod values from SnapshotPolicies."""
    out: dict[tuple[str, str], set[str]] = {}
    for policy_dir in POLICY_PATHS[cluster]:
        if not policy_dir.is_dir():
            continue
        files = list(policy_dir.glob("*.yaml")) + list(policy_dir.glob("*.yml"))
        for path in files:
            for doc in load_docs(path):
                if not is_snapshot_policy(doc):
                    continue
                spec = doc.get("spec") or {}
                method = spec.get("copyMethod") or "Snapshot"
                ns = (doc.get("metadata") or {}).get("namespace")
                if not isinstance(ns, str) or not ns:
                    continue
                for src in spec.get("sources") or []:
                    if not isinstance(src, dict):
                        continue
                    pvc = src.get("pvc") or {}
                    name = pvc.get("name") if isinstance(pvc, dict) else None
                    if isinstance(name, str) and name:
                        out.setdefault((ns, name), set()).add(str(method))
    return out


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
    out_of_band: dict[str, set[str]] = {c: set() for c in CLUSTERS}
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
        if entry.get("outOfBand") is True:
            out_of_band[cluster].add(namespace)
    return out, out_of_band


def main() -> int:
    exemptions, out_of_band = load_exemptions()
    failures: list[str] = []
    stale: list[str] = []
    failures.extend(multi_source_policies())

    for cluster in CLUSTERS:
        pvc_ns = pvc_namespaces(cluster)
        covered = policy_namespaces(cluster)
        exempt = exemptions[cluster]

        for namespace in sorted(pvc_ns - covered - set(exempt)):
            failures.append(
                f"{cluster}/{namespace}: declares a PVC/VCT/CNPG volume in Git "
                f"but has no Kopiur SnapshotPolicy and no exemption"
            )

        for namespace in sorted(set(exempt) - pvc_ns - out_of_band[cluster]):
            stale.append(
                f"{cluster}/{namespace}: exemption has no matching Git-declared "
                f"PVC namespace on this cluster (remove or fix the entry)"
            )
        for namespace in sorted(set(exempt) & covered):
            stale.append(
                f"{cluster}/{namespace}: exempted but also has a SnapshotPolicy "
                f"(drop the exemption or the policy)"
            )

        methods = policy_pvc_copy_methods(cluster)
        for namespace, pvc_name in local_path_pvcs(cluster):
            if namespace in exempt:
                continue
            used = methods.get((namespace, pvc_name), set())
            if not used:
                if namespace in covered:
                    failures.append(
                        f"{cluster}/{namespace}/{pvc_name}: Git-declared "
                        f"local-path PVC is not listed as a SnapshotPolicy source"
                    )
                continue
            if used != {"Direct"}:
                failures.append(
                    f"{cluster}/{namespace}/{pvc_name}: local-path/hostPath PVC "
                    f"requires Kopiur copyMethod: Direct (got {sorted(used)}); "
                    f"CSI Snapshot cannot capture rancher.io/local-path volumes"
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
