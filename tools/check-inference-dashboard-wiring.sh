#!/usr/bin/env bash
# Fail if AI inference Grafana dashboards drift out of the vllm kustomization,
# or if the primary vLLM dashboard loses required variables / hard-codes models.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT"

python3 - <<'PY'
from pathlib import Path
import sys

kdir = Path("kubernetes/apps/base/monitoring/grafana/dashboards/vllm")
kust = (kdir / "kustomization.yaml").read_text()
siblings = sorted(p.name for p in kdir.glob("*.yaml") if p.name != "kustomization.yaml")
missing = [name for name in siblings if name not in kust]
if missing:
    sys.exit(f"UNLISTED inference dashboards (would orphan on Flux apply): {missing}")

# SGLang dashboard intentionally removed — runtime is vLLM only.
if "sglang.yaml" in siblings or "sglang.yaml" in kust:
    sys.exit("sglang.yaml must stay removed (no live SGLang runtime; use vllm-inference)")

required = {"dashboards.yaml", "gpu-dcgm.yaml", "vllm-inference.yaml"}
if not required.issubset(set(siblings)):
    sys.exit(f"missing required inference dashboard files: {sorted(required - set(siblings))}")

vllm = (kdir / "vllm-inference.yaml").read_text()
for var in ("job", "model", "workload", "container"):
    if f'"name": "{var}"' not in vllm:
        sys.exit(f"vllm-inference dashboard missing templating variable {var}")
if "vllm:num_requests_running" not in vllm:
    sys.exit("vllm-inference dashboard missing vllm:num_requests_running panels")
if "mimir-stpetersburg" not in vllm:
    sys.exit("vllm-inference must pin datasource uid mimir-stpetersburg")

# Upstream imports must map DS_PROMETHEUS to the uid, not the display name.
dash = (kdir / "dashboards.yaml").read_text()
if "datasourceName: mimir-stpetersburg" not in dash:
    sys.exit("dashboards.yaml must map DS_PROMETHEUS -> mimir-stpetersburg (uid)")
if "datasourceName:" in dash:
    after = dash.split("datasourceName:", 1)[1][:80]
    if "Mimir-StPetersburg" in after:
        sys.exit("dashboards.yaml must not use display name Mimir-StPetersburg as datasourceName")

print("✓ inference Grafana dashboard wiring (vLLM primary; SGLang removed)")
PY
