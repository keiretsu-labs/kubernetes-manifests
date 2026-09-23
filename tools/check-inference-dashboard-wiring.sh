#!/usr/bin/env bash
# Fail if AI inference Grafana dashboards drift out of the vllm kustomization,
# or if the SGLang dashboard reintroduces hard-coded model/pod names in exprs.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT"

DIR=kubernetes/apps/base/monitoring/grafana/dashboards/vllm
KUST="$DIR/kustomization.yaml"

python3 - <<'PY'
from pathlib import Path
import re
import sys

root = Path(".")
kdir = root / "kubernetes/apps/base/monitoring/grafana/dashboards/vllm"
kust = (kdir / "kustomization.yaml").read_text()
siblings = sorted(p.name for p in kdir.glob("*.yaml") if p.name != "kustomization.yaml")
missing = [name for name in siblings if name not in kust]
if missing:
    sys.exit(f"UNLISTED inference dashboards (would orphan on Flux apply): {missing}")

sglang = (kdir / "sglang.yaml").read_text()
# Hard-coded model IDs in PromQL are a swap footgun; variables are required.
hard = re.findall(r'model_name=~\\?"?(GLM|Qwen)[^"\\s,}]*', sglang)
if hard:
    sys.exit(f"sglang dashboard hard-codes model_name values: {hard}")
if 'pod=~\\"qwen38-.*\\"' in sglang or "pod=~\\\"qwen38-.*\\\"" in sglang:
    sys.exit("sglang OOM panels still hard-code pod=~qwen38-.*; use $${workload}")
if 'container=\\"sglang\\"' in sglang and "$${container}" not in sglang:
    sys.exit("sglang OOM panels still hard-code container=sglang; use $${container}")
for var in ("target", "model", "workload", "container"):
    if f'"name": "{var}"' not in sglang:
        sys.exit(f"sglang dashboard missing templating variable {var}")
print("✓ inference Grafana dashboard wiring")
PY
