#!/usr/bin/env bash
# Fail if AI inference Grafana dashboards drift out of the vllm kustomization,
# or if the primary vLLM dashboard loses required variables / hard-codes models.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT"

python3 - <<'PY'
from pathlib import Path
import re
import sys

kdir = Path("kubernetes/apps/base/monitoring/grafana/dashboards/vllm")
kust = (kdir / "kustomization.yaml").read_text()
siblings = sorted(p.name for p in kdir.glob("*.yaml") if p.name != "kustomization.yaml")
missing = [name for name in siblings if name not in kust]
if missing:
    sys.exit(f"UNLISTED inference dashboards (would orphan on Flux apply): {missing}")

required = {"dashboards.yaml", "gpu-dcgm.yaml", "sglang.yaml", "vllm-inference.yaml"}
if not required.issubset(set(siblings)):
    sys.exit(f"missing required inference dashboard files: {sorted(required - set(siblings))}")

vllm = (kdir / "vllm-inference.yaml").read_text()
for var in ("job", "model", "workload", "container"):
    if f'"name": "{var}"' not in vllm:
        sys.exit(f"vllm-inference dashboard missing templating variable {var}")
if "vllm:num_requests_running" not in vllm:
    sys.exit("vllm-inference dashboard missing vllm:num_requests_running panels")
if "uid\": \"mimir-stpetersburg\"" not in vllm and 'uid": "mimir-stpetersburg"' not in vllm:
    # after $$ escaping the json may still contain mimir-stpetersburg
    if "mimir-stpetersburg" not in vllm:
        sys.exit("vllm-inference must pin datasource uid mimir-stpetersburg")

# Upstream imports must map DS_PROMETHEUS to the uid, not the display name.
dash = (kdir / "dashboards.yaml").read_text()
if "datasourceName: mimir-stpetersburg" not in dash:
    sys.exit("dashboards.yaml must map DS_PROMETHEUS -> mimir-stpetersburg (uid)")
if "Mimir-StPetersburg" in dash.split("datasourceName:")[1][:80] if "datasourceName:" in dash else "":
    sys.exit("dashboards.yaml must not use display name Mimir-StPetersburg as datasourceName")

sglang = (kdir / "sglang.yaml").read_text()
if 'pod=~\\"qwen38-.*\\"' in sglang and "$${workload}" not in sglang:
    sys.exit("sglang OOM panels still hard-code pod=~qwen38-.*; use $${workload}")
if 'container=\\"sglang\\"' in sglang and "$${container}" not in sglang:
    sys.exit("sglang OOM panels still hard-code container=sglang; use $${container}")

print("✓ inference Grafana dashboard wiring (vLLM primary + SGLang retained)")
PY
