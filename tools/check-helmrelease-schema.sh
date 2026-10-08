#!/usr/bin/env bash
# Validate authored Flux HelmRelease v2 objects against the pinned local CRD.
# Flate renders HelmRelease charts into their workload resources, so its output
# does not retain the HelmRelease CRs this schema gate needs to inspect.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

schema_root="$ROOT/tools/schemas/helm-controller-v1.6.5"
schema="$schema_root/helmrelease-helm-v2-strict.json"
schema_location="$schema"
provenance="$schema_root/provenance.json"
[ -s "$schema" ] || { echo "error: missing local HelmRelease schema: $schema" >&2; exit 2; }
[ -s "$provenance" ] || { echo "error: missing schema provenance: $provenance" >&2; exit 2; }

python3 - "$provenance" "$schema" "$ROOT/clusters/common/bootstrap/flux/kustomization.yaml" <<'PY'
import hashlib, json, pathlib, re, sys
provenance, schema, bootstrap = map(pathlib.Path, sys.argv[1:])
lock = json.loads(provenance.read_text())
actual = hashlib.sha256(schema.read_bytes()).hexdigest()
if actual != lock["generatedSchemaSha256"]:
    raise SystemExit("schema artifact hash does not match provenance")
match = re.search(r"flux2/manifests/install\?ref=v([0-9.]+)", bootstrap.read_text())
if not match:
    raise SystemExit("cannot find the Flux bootstrap version")
if match.group(1) != lock["fluxVersion"]:
    raise SystemExit(
        f"Flux bootstrap is v{match.group(1)}, schema provenance is v{lock['fluxVersion']}"
    )
PY

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT INT TERM
targets=(talos-ottawa talos-robbinsdale talos-stpetersburg)
if [ "$#" -gt 1 ]; then
  echo "usage: $0 [talos-ottawa|talos-robbinsdale|talos-stpetersburg]" >&2
  exit 2
elif [ "$#" = 1 ]; then
  case "$1" in
    ot|ottawa|talos-ottawa) targets=(talos-ottawa) ;;
    rb|robbinsdale|talos-robbinsdale) targets=(talos-robbinsdale) ;;
    sp|stpetersburg|talos-stpetersburg) targets=(talos-stpetersburg) ;;
    *) echo "error: unknown cluster '$1'" >&2; exit 2 ;;
  esac
fi

selected="$tmp/helmreleases.yaml"
# HelmRelease objects are authored once in kubernetes/apps/base. Validate those
# CRs directly: resolving charts here is unnecessary and can fail on unrelated
# sources before kubeconform gets the objects. The full Flate cluster render
# remains responsible for overlays, substitutions, chart sources, and readiness.
count="$(python3 - "$ROOT/kubernetes/apps/base" "$selected" <<'PY'
import pathlib, sys, yaml
root, target = map(pathlib.Path, sys.argv[1:])
selected = []
files = sorted(
    path for suffix in ("*.yaml", "*.yml") for path in root.rglob(suffix)
    if path.is_file()
)
for source in files:
    text = source.read_text()
    if "kind: HelmRelease" not in text:
        continue
    try:
        documents = list(yaml.load_all(text, Loader=yaml.BaseLoader))
        nodes = list(yaml.compose_all(text, Loader=yaml.BaseLoader))
    except yaml.YAMLError as error:
        raise SystemExit(f"{source.relative_to(root)}: invalid YAML: {error}")
    if len(documents) != len(nodes):
        raise SystemExit(f"{source.relative_to(root)}: YAML document accounting mismatch")
    for document, node in zip(documents, nodes):
        if not isinstance(document, dict) or document.get("kind") != "HelmRelease":
            continue
        api_version = document.get("apiVersion")
        if api_version != "helm.toolkit.fluxcd.io/v2":
            raise SystemExit(
                f"{source.relative_to(root)}: unsupported HelmRelease API version "
                f"{api_version!r}; update the pinned schema"
            )
        selected.append(text[node.start_mark.index:node.end_mark.index])
if not selected:
    raise SystemExit(f"no HelmRelease v2 source documents found under {root}")
with target.open("w") as stream:
    for document in selected:
        stream.write("---\n")
        stream.write(document)
        if not document.endswith("\n"):
            stream.write("\n")
print(len(selected))
PY
)"
case "$count" in ''|*[!0-9]*) echo "error: invalid HelmRelease count: $count" >&2; exit 2;; esac
[ "$count" -gt 0 ] || { echo "error: no HelmRelease v2 source resources found" >&2; exit 1; }
tools/kubeconform.sh -strict -schema-location "$schema_location" \
  -output text -summary "$selected"
echo "HelmRelease v2 schema OK (validated $count source resources)"
