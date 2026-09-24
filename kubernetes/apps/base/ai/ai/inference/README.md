# AI inference on 2× NVIDIA DGX Spark

## Active deployment: GLM-5.3-Flash EXL3/TR3

- **Model:** `Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw`
- **Model revision:** `25a44fdbf16862a46b7cc9921142c6c81350af2f`
- **Runtime:** generic `vllm` LeaderWorkerSet using the MiaAI-Lab TP=2 recipe
  with conservative eager execution
- **Image:** `ghcr.io/miaai-lab/glm-5.3-flash-2x-dgx-sparks:exl3-instanttensor@sha256:447114ee77d14c9b4732ee23978ada2a0ee9027868a231d6fd42700a8b25be1d`
- **Draft model:** `incoai/GLM-5.3-Flash-DFlash2@dc77ff1c99eeb2df044ee3d4f0094eb033fee410`
- **Topology:** one LeaderWorkerSet spanning `spark-0` and `spark-1`, TP=2, MP executor
- **Serving ID:** `GLM-5.3-Flash-EXL3`
- **Service:** `model-serving.ai:8000` (generic identity for future model swaps)

**Mia source-aligned, shared-cluster serving profile:**

- [MiaAI-Lab's `tp2-long-coding.env`](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks/blob/main/examples/tp2-long-coding.env)
  is the source for runtime improvements, but its clean-benchmark `.865`
  utilization and automatic large KV pool are not safe assumptions here because
  these Sparks also carry the rest of the St. Petersburg workload.
- The deployed qualification target is 262,144 tokens per request, up to two
  admitted sequences, and 1,024 batched prefill tokens. The fixed 4.5 GiB KV cap,
  rather than the request limit, controls total cached context.
- E3 grouped prefill (`EXL3_FAT_GROUPED=1`, temp rows 32) and fair scheduling;
  eager execution is enabled for reliable startup because graph capture stalled
  this cluster during the previous rescue boot.
- DFlash2 artifacts remain cached for a future qualified rollout, but speculative
  decoding is disabled in this shared-cluster profile; the init gate checks
  `MemAvailable` before vLLM starts and the model runs in language-only mode to
  leave memory for the other Spark workloads.
- Explicit 4.5 GiB FP8 KV budget (`4831838208` bytes) is qualified for this
  shared-cluster profile. A safe boot reported 568,971 logical KV tokens
  (2.17 concurrent 262,144-token requests); the exact total is runtime-dependent
  and must be confirmed from the vLLM capacity log after each rollout.
- The TP ranks use a one-hour NCCL/Gloo distributed timeout and engine-ready
  timeout so rank 1 is not evicted by the default 30-minute wait while rank 0
  loads the 164 GiB InstantTensor checkpoint.

This follows MiaAI-Lab's runtime/image recipe, with a lower memory profile
qualified for this shared cluster. Do not raise context length, concurrency,
KV budget, or GPU utilization without a new memory qualification.

The existing per-rank PVCs and `/models/qwen38` storage path retain their legacy
names to reuse the downloaded checkpoint. The workload, pod, Service, mesh
export, probes, and consumer route use generic `vllm`/`model-serving` names.

## Safety and rollout notes

- Both Sparks are consumed by this single TP=2 workload; there is no spare GPU for a parallel model.
- The TP ranks use the `ai-inference` priority class and remain pinned to
  spark-0/spark-1 because the RDMA addresses and per-rank PVCs are node-specific.
- Each rank keeps the existing 90Gi request / 96Gi limit and a bounded startup memory gate.
- The workload identity is `vllm`; the `model-serving` Service and mesh identity are stable across model swaps.
- Acceptance requires both ranks ready, `/health` 200, `/v1/models` advertising `GLM-5.3-Flash-EXL3`, and a bounded completion response.
- CLIProxy advertises the deployed 262,144-token window; it does not infer
  availability from the static catalog, so health and completion checks remain
  part of rollout acceptance.
