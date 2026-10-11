#!/usr/bin/env python3
"""Catch unresolved Flux postBuild variables in locally rendered Kustomizations.

Only key names from encrypted Secrets are read. Secret values are never rendered
or printed. The app parent patches the common substitution stack into children.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml


VARIABLE = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
LOCATIONS = ("ottawa", "robbinsdale", "stpetersburg")
class ManifestLoader(yaml.SafeLoader):
    pass


# Kustomize emits unquoted `matchType: =` in some Prometheus rules. YAML 1.1
# assigns '=' a special tag that PyYAML's SafeLoader otherwise cannot load.
ManifestLoader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def documents(path):
    return [item for item in yaml.load_all(path.read_text(), Loader=ManifestLoader) if isinstance(item, dict)]


def keys_for(root, location, source):
    name = source.get("name", "")
    kind = source.get("kind", "")
    if (kind, name) == ("ConfigMap", "common-settings"):
        path = root / "clusters/common/flux/vars/common-settings.yaml"
    elif (kind, name) == ("Secret", "common-secrets"):
        path = root / "clusters/common/flux/vars/common-secrets.sops.yaml"
    elif (kind, name) == ("ConfigMap", "cluster-settings"):
        path = root / f"clusters/talos-{location}/flux/vars/cluster-settings.yaml"
    elif (kind, name) == ("Secret", "cluster-secrets"):
        path = root / f"clusters/talos-{location}/flux/vars/cluster-secrets.sops.yaml"
    else:
        # An optional source can be created by another Flux Kustomization. Its
        # keys cannot be proved from this repository's static variable files.
        return set()
    if not path.is_file():
        raise ValueError(f"missing substitution source: {path.relative_to(root)}")
    result = set()
    for doc in documents(path):
        result.update(doc.get("data", {}))
        result.update(doc.get("stringData", {}))
    return result


def tokens(value):
    """Yield (name, spelling, malformed) for Flux's braced expressions."""
    pos = 0
    while pos < len(value):
        if value[pos] != "$" or pos + 1 == len(value):
            pos += 1
            continue
        if value[pos + 1] == "$":
            pos += 2
            continue
        if value[pos + 1] == "{":
            end = value.find("}", pos + 2)
            if end < 0:
                pos += 2
                continue
            body = value[pos + 2:end]
            match = VARIABLE.match(body)
            if match:
                suffix = body[match.end():]
                if not suffix:
                    yield match.group(), value[pos:end + 1], False
                elif suffix.startswith((":-", ":=", ":+")):
                    pass  # These are the supported Flux default/alternate forms.
                elif suffix.startswith(("-", "+", "?", ":")):
                    yield match.group(), value[pos:end + 1], True
                else:
                    # Shell expansions such as ${age##...} are not evaluated
                    # by Flux, but strict mode still requires `age` to exist.
                    yield match.group(), value[pos:end + 1], False
            pos = end + 1
            continue
        pos += 1


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from strings(key)
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def render(root, path):
    directory = root / path
    if not directory.is_dir() or not directory.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"invalid spec.path: {path}")
    if any((directory / name).exists() for name in ("kustomization.yaml", "kustomization.yml", "Kustomization")):
        proc = subprocess.run(
            ["kustomize", "build", "--enable-helm", "--load-restrictor=LoadRestrictionsNone", str(directory)],
            text=True, capture_output=True, check=False, timeout=90,
        )
        if proc.returncode:
            raise ValueError(f"render failed for {path}: {proc.stderr.strip()[:300]}")
        return [doc for doc in yaml.load_all(proc.stdout, Loader=ManifestLoader) if isinstance(doc, dict)]
    # Flux generates a kustomization for plain manifest directories.
    result = []
    for file in sorted(directory.glob("*.yaml")):
        if not file.name.endswith(".sops.yaml"):
            result.extend(documents(file))
    return result


def inherited_sources(root, location):
    path = root / f"clusters/talos-{location}/flux/config/cluster.yaml"
    for doc in documents(path):
        if doc.get("kind") == "Kustomization" and doc.get("metadata", {}).get("name") == "kubernetes-apps":
            for patch in doc.get("spec", {}).get("patches", []):
                content = yaml.safe_load(patch.get("patch", "")) or {}
                sources = content.get("spec", {}).get("postBuild", {}).get("substituteFrom", [])
                if sources:
                    return sources
    return []


def run(root, target):
    errors = []
    rendered = {}
    source_keys = {}
    for location in LOCATIONS:
        if target and target != location:
            continue
        inherited = inherited_sources(root, location)
        candidates = list((root / "kubernetes/apps" / location).rglob("*.yaml"))
        candidates += list((root / f"clusters/talos-{location}").rglob("*.yaml"))
        for file in sorted(candidates):
            for pointer in documents(file):
                if pointer.get("kind") != "Kustomization" or not str(pointer.get("apiVersion", "")).startswith("kustomize.toolkit.fluxcd.io/"):
                    continue
                spec = pointer.get("spec", {})
                if spec.get("sourceRef", {}).get("name") != "kubernetes-manifests":
                    continue  # Foreign Git/OCI sources are unavailable offline.
                path = str(spec.get("path", "")).removeprefix("./")
                if not path:
                    continue
                child = file.is_relative_to(root / "kubernetes/apps" / location)
                post = spec.get("postBuild", {})
                sources = inherited if child and inherited else post.get("substituteFrom", [])
                if child and inherited:
                    sources = inherited + [s for s in post.get("substituteFrom", []) if s not in inherited]
                if not sources and not post.get("substitute"):
                    continue
                provided = set(post.get("substitute", {}))
                for source in sources:
                    cache_key = (location, source.get("kind"), source.get("name"))
                    if cache_key not in source_keys:
                        source_keys[cache_key] = keys_for(root, location, source)
                    provided.update(source_keys[cache_key])
                if path not in rendered:
                    rendered[path] = render(root, path)
                for obj in rendered[path]:
                    annotation = obj.get("metadata", {}).get("annotations", {})
                    if annotation.get("kustomize.toolkit.fluxcd.io/substitute") == "disabled":
                        continue
                    identity = f"{obj.get('kind', '?')}/{obj.get('metadata', {}).get('name', '?')}"
                    missing = {spelling for value in strings(obj) for key, spelling, malformed in tokens(value) if malformed or key not in provided}
                    for spelling in sorted(missing):
                        errors.append(f"{file.relative_to(root)}: {identity} ({path}): unresolved {spelling}")
    for error in sorted(set(errors)):
        print(error, file=sys.stderr)
    return bool(errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("cluster", nargs="?", choices=LOCATIONS)
    args = parser.parse_args()
    try:
        return int(run(args.root.resolve(), args.cluster))
    except (OSError, ValueError, yaml.YAMLError, subprocess.TimeoutExpired) as error:
        print(f"envsubst check: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
