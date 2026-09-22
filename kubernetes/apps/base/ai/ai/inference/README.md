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
**Mia practical coding profile ported:**
- 262,144 tokens per request, two active sequences, 1,024 batched prefill tokens.
- E3 grouped prefill (`EXL3_FAT_GROUPED=1`, temp rows 32) and fair scheduling.
- Fast MoE decode, KDA BF16 large-M prefill, and dense/KDA FP8 opt-ins enabled.
- DFlash2 fixed at k=7 with draft TP=2; adaptive-K remains off.
- Vision remains enabled with 48-image/1-video ceiling, 2,048 image tokens, and 1 GiB media cache.
- Explicit 15 GiB FP8 KV budget retained to preserve host headroom.

This is the practical responsive long-session profile from Mia’s September 2026 report. The three opt-ins add roughly 3.3 GiB per GPU and dense/KDA FP8 changes numerics; they are deliberate performance/memory tradeoffs, not free capacity.

The Mia recipe uses the published arm64 image directly; no image build or runtime patch ConfigMap is required. The model and DFlash2 weights are downloaded to the existing per-rank 200Gi PVCs and pinned by immutable Hugging Face revisions.

## Safety and rollout notes

- Both Sparks are consumed by this single TP=2 workload; there is no spare GPU for a parallel model.
- Each rank keeps the existing 90Gi request / 96Gi limit and cache-drop guardrails.
- The replacement is staged as one LWS generation, with the existing Service and mesh identity preserved.
- Acceptance requires both ranks ready, `/health` 200, `/v1/models` advertising `GLM-5.3-Flash-EXL3`, and a bounded completion response.
- The published Mia recipe reports 850K as its current safer default on this hardware; do not raise context or GPU utilization without a new memory qualification.
