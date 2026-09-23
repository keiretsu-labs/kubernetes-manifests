#!/usr/bin/env bash
# Assert Garage gateway ingress preserves cross-cluster peer RPC/admin scope.
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

import yaml

path = pathlib.Path("kubernetes/apps/base/garage/garage/garage-gateway-ingress.yaml")
docs = [d for d in yaml.safe_load_all(path.read_text()) if d]
if len(docs) != 1:
    raise SystemExit(f"expected 1 document, got {len(docs)}")
doc = docs[0]
if doc.get("kind") != "CiliumNetworkPolicy":
    raise SystemExit(f"unexpected kind {doc.get('kind')}")
if doc.get("metadata", {}).get("name") != "garage-gateway-ingress":
    raise SystemExit("policy name must be garage-gateway-ingress")

spec = doc["spec"]
selector = spec.get("endpointSelector", {}).get("matchLabels", {})
if selector.get("garage.rajsingh.info/tier") != "gateway":
    raise SystemExit("endpointSelector must target garage.rajsingh.info/tier=gateway")
if selector.get("app.kubernetes.io/instance") != "garage":
    raise SystemExit("endpointSelector must target app.kubernetes.io/instance=garage")

ingress = spec.get("ingress") or []
if not ingress:
    raise SystemExit("ingress rules missing")

def ports_of(rule):
    out = set()
    for tp in rule.get("toPorts") or []:
        for p in tp.get("ports") or []:
            out.add((str(p.get("port")), p.get("protocol", "TCP")))
    return out

def entities_of(rule):
    return set(rule.get("fromEntities") or [])

peer_rule = None
for rule in ingress:
    eps = rule.get("fromEndpoints") or []
    labels = [ep.get("matchLabels") or {} for ep in eps]
    tiers = {lbl.get("garage.rajsingh.info/tier") for lbl in labels}
    if "gateway" in tiers and "storage" in tiers:
        peer_rule = rule
        break

if peer_rule is None:
    raise SystemExit("missing fromEndpoints peer rule covering gateway+storage tiers")

peer_ports = ports_of(peer_rule)
need = {("3901", "TCP"), ("3903", "TCP")}
if not need.issubset(peer_ports):
    raise SystemExit(f"peer rule must allow 3901/3903 TCP, got {sorted(peer_ports)}")
# Must not open S3/web to every garage mesh peer.
forbidden = {("3900", "TCP"), ("3902", "TCP")}
if peer_ports & forbidden:
    raise SystemExit(f"peer rule must not allow client ports 3900/3902, got {sorted(peer_ports)}")

# Local cluster must still cover client + peer ports.
cluster_rules = [r for r in ingress if "cluster" in entities_of(r)]
if not cluster_rules:
    raise SystemExit("missing fromEntities: cluster rule")
cluster_ports = set()
for r in cluster_rules:
    cluster_ports |= ports_of(r)
for port in ("3900", "3901", "3902", "3903"):
    if (port, "TCP") not in cluster_ports:
        raise SystemExit(f"cluster rule missing port {port}")

# Envoy cross-cluster backends: namespace-scoped, client ports only.
envoy_rule = None
for rule in ingress:
    for ep in rule.get("fromEndpoints") or []:
        lbl = ep.get("matchLabels") or {}
        if lbl.get("k8s:io.kubernetes.pod.namespace") == "envoy-gateway-system":
            envoy_rule = rule
            break
if envoy_rule is None:
    raise SystemExit("missing envoy-gateway-system fromEndpoints rule")
envoy_ports = ports_of(envoy_rule)
if not {("3900", "TCP"), ("3902", "TCP")}.issubset(envoy_ports):
    raise SystemExit(f"envoy rule must allow 3900/3902, got {sorted(envoy_ports)}")
if envoy_ports & {("3901", "TCP"), ("3903", "TCP")}:
    raise SystemExit("envoy rule must not open peer ports 3901/3903")

# No bare $ that Flux envsubst would mangle (use $${...} if needed).
text = path.read_text()
# Allow commentary; fail on unescaped Flux-like ${VAR} or regex $ anchors in values.
import re
for i, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    if re.search(r"(?<!\$)\$\{[A-Za-z_][A-Za-z0-9_]*\}", line):
        raise SystemExit(f"line {i}: bare Flux ${{VAR}} — use a Secret/ConfigMap or $$")
    # Cilium http path regex anchors must be doubled for Flux: /health$$ 
    if re.search(r"path:\s*.*\$(?!\$)", line):
        raise SystemExit(f"line {i}: raw $ anchor — write $$ for Flux envsubst")

print("garage-gateway-ingress peer scope OK")
PY
