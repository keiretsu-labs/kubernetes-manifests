# Grafana AI inference dashboards

## Diagnosis (2026-09-23)

Why the AI folder looked broken after the Mia GLM / vLLM cutover:

| Dashboard | What it queries | Against current runtime |
|---|---|---|
| **SGLang Inference** | `sglang:*` metrics, historically `container="sglang"` | **Empty** — runtime is `vllm` and exports `vllm:*` |
| **vLLM Performance / Queries** (upstream URL import) | `vllm:*` via `${DS_PROMETHEUS}` → uid `mimir-stpetersburg` | Correct family; `$Deployment_id` defaults to upstream's `granite-*` until variable refresh |
| **NVIDIA DCGM** | `DCGM_FI_*` on `mimir-stpetersburg` | Works (GPU series present) |

Live facts (Mimir tenant `talos-stpetersburg`):

- ServiceMonitor `ai/qwen38` scrapes job `qwen38`, container `vllm`
- Series labels include `model_name=GLM-5.3-Flash-EXL3` (and dual served name when enabled)
- Instant gaps during LWS restarts are expected; range queries still show history

## Fix

- **Primary:** Grafana → AI → **vLLM Inference** (`vllm-inference`), label-driven `$job` / `$model` / `$workload` / `$container`
- Keep SGLang dashboard listed for SGLang-metric eras; do not drop it from kustomization (#2573)
- Upstream JSON imports retained as secondary; prefer the local vLLM dashboard for ops

## Guards

- `tools/check-inference-dashboard-wiring.sh` — siblings listed, vLLM vars present, no hard-coded OOM selectors
- `tools/orphans.sh` — UNLISTED file detection
