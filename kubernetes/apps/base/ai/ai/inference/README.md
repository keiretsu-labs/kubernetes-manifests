# AI inference on 2× NVIDIA DGX Spark

## Active deployment: GLM-5.3-Flash EXL3/TR3

- **Model:** `Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw`
- **Model revision:** `25a44fdbf16862a46b7cc9921142c6c81350af2f`
- **Runtime:** MiaAI-Lab TP=2 recipe with DFlash2
- **Image:** `ghcr.io/miaai-lab/glm-5.3-flash-2x-dgx-sparks:exl3-instanttensor@sha256:447114ee77d14c9b4732ee23978ada2a0ee9027868a231d6fd42700a8b25be1d`
- **Draft model:** `incoai/GLM-5.3-Flash-DFlash2@dc77ff1c99eeb2df044ee3d4f0094eb033fee410`
- **Topology:** one LeaderWorkerSet spanning `spark-0` and `spark-1`, TP=2, MP executor
- **Serving ID:** `GLM-5.3-Flash-EXL3`
- **Service:** `qwen38.ai:8000` (identity retained so CLIProxy, mesh export, probes, and consumers cut over atomically)
- **Context guardrail:** `850000` tokens, `max-num-seqs=4`
- **KV:** FP8; `gpu-memory-utilization=0.85`; `max-num-batched-tokens=7168`
- **Speculative decoding:** DFlash2, 7 draft tokens, draft TP=2
- **Vision:** enabled; maximum 48 images / 1 video per prompt, 2048 tokens per image, 1 GiB media cache, max-size multimodal profiling disabled

The Mia recipe uses the published arm64 image directly; no image build or runtime patch ConfigMap is required. The model and DFlash2 weights are downloaded to the existing per-rank 200Gi PVCs and pinned by immutable Hugging Face revisions.

## Safety and rollout notes

- Both Sparks are consumed by this single TP=2 workload; there is no spare GPU for a parallel model.
- Each rank keeps the existing 90Gi request / 96Gi limit and cache-drop guardrails.
- The replacement is staged as one LWS generation, with the existing Service and mesh identity preserved.
- Acceptance requires both ranks ready, `/health` 200, `/v1/models` advertising `GLM-5.3-Flash-EXL3`, and a bounded completion response.
- The published Mia recipe reports 850K as its current safer default on this hardware; do not raise context or GPU utilization without a new memory qualification.
