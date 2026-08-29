# AI Inference on DGX Spark (GB10 Blackwell)

## Hardware: NVIDIA DGX Spark / SM121 / GB10

- **GPU**: NVIDIA GB10 Grace Blackwell Superchip (SM_121, compute capability 12.1)
- **Memory**: 128GB LPDDR5X **unified** (shared between CPU and GPU — no dedicated VRAM)
- **Bandwidth**: ~273 GB/s (LPDDR5X), ~600 GB/s NVLink-C2C between CPU/GPU dies
- **Tensor Cores**: 192x 5th-gen (native FP4/FP6/FP8 support)
- **FP4 Peak**: ~1 PFLOP (1000 TOPS)
- **CPU**: 10x Cortex-X925 + 10x Cortex-A725 (ARM64)
- **CUDA**: Requires CUDA 13.0+
- **OS**: Talos Linux v1.12.2

## Active Setup: vLLM GLM-5.3-Flash EXL3

**Model**: `Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw` (~164GiB, 120 safetensor
shards, EXL3 MoE)
**Image**: `ghcr.io/miaai-lab/glm-5.3-flash-2x-dgx-sparks@sha256:9bb1557a4234fce63d59599e44d10747eabd742beb337eebf9e7070be8a0fd58`
(published ARM64/SM121 runtime; no in-repo image build)
**Deployment**: `glm53.yaml`, a two-member LeaderWorkerSet pinned to `spark-0`
and `spark-1`, with vLLM TP=2 over the RDMA rail.
**Serving profile**: 1,000,000-token context, packed FP8 sparse-MLA KV cache,
and DFlash2 speculative decoding (k=7).
**Endpoint**: `stpetersburg-vllm` (port 80 → 8000), also exposed internally as
the `glm53` Service and the compatibility `vllm` Service.

The OpenAI-compatible model ID is `GLM-5.3-Flash-EXL3`. CLIProxy exposes the
canonical `vllm/GLM-5.3-Flash-EXL3` route and the stable client alias
`vllm/GLM-5.3-Flash`. The route advertises a 1,000,000-token context and
reasoning support through the GLM parsers (`glm47` tool calls and `glm45`
reasoning). The Bhaiya default is the CLIProxy alias, so clients remain on the
managed gateway instead of dialing the DGX endpoint directly.

The model recipe and image are published by
[`MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks`](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks).
The manifest pins both the model and DFlash2 revisions and validates the
downloaded files before vLLM starts.

### Operational guardrails

- This is one TP=2 LWS group spanning both Sparks: `spark-0` is rank 0 and
  `spark-1` is rank 1. There is no spare GPU for test workloads.
- Each vLLM rank requests `94Gi` and is limited to `96Gi`; the model PVCs are
  separate per rank. The cache-drop init container and bounded cache-drop loop
  reclaim unified memory before and during serving.
- The published image's GB10 overlay is applied in the serving container before
  vLLM starts, disabling the known `persistent_topk` SMEM path on this GPU.
- The memory-sensitive serving settings are `--gpu-memory-utilization 0.76` on
  the leader and `0.75` on the worker, plus `--enforce-eager` and
  `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0`, with a
  `1000000` context, `--max-num-seqs 4`, `--max-num-batched-tokens 512`, and
  DFlash2 with seven speculative tokens. The worker's free-memory preflight
  caps it at `0.75`; eager mode leaves the budget for KV-cache blocks instead
  of CUDA graph capture, while the 512-token batch cap keeps the post-weight
  activation profile inside the remaining headroom. The
  upstream recipe's `0.87` budget fails the same preflight under the Spark
  Kubernetes CUDA reservation. Do not change these settings or place
  unrelated GPU workloads on either Spark without a new load qualification.
- Metrics are scraped once by the `glm53` ServiceMonitor at 15-second
  intervals and stored in the St. Petersburg Mimir tenant. Do not add a second
  static ScrapeConfig for this Service; duplicate scrapes double-count counter
  rates and waste the agent's remote-write budget.
- The shared Grafana vLLM dashboards cover throughput, queue/KV headroom,
  latency, and DCGM Spark GPU panels. The vLLM metrics endpoint is scraped only
  by the ServiceMonitor above.
- The model-download init step validates the pinned GLM revision and DFlash2
  revision on each start. It uses separate local-path PVCs because the two
  Spark nodes cannot mount one ReadWriteOnce volume.
- Velero's bounded repository-maintenance jobs are deliberately spread across
  the two worker nodes; they have a `2Gi` memory ceiling and must not be
  changed to unbounded batch workloads.

## Historical alternative: llama.cpp (not deployed)

**Model**: `unsloth/Qwen3-Coder-Next-GGUF` (UD-Q4_K_XL, ~46GB)
**Image**: `ghcr.io/ardge-labs/llama-cpp-dgx-spark:server`
**Performance**: ~33 tok/s decode, ~170 tok/s prefill

### Key Config Decisions

| Setting | Value | Why |
|---------|-------|-----|
| `--n-gpu-layers 99` | Force all layers to GPU | `--fit on` miscalculates unified memory, only offloads 34/49 layers |
| `--parallel 1` | Single slot | OpenCode sends >32K token prompts; splitting context across slots causes "context exceeded" |
| `-c 131072` | 131K context | Needed for coding agents with large system prompts + file context |
| `--seed 3407` | Fixed seed | Unsloth recommended |
| `--jinja` | Jinja templates | Required for tool calling / chat templates |
| No `--flash-attn` | Omitted | Not in Unsloth docs; auto mode is default |
| No `--cache-type-k/v` | Omitted | Not in Unsloth docs; default is fine |

### Sampling (per Unsloth docs)
- `--temp 1.0`, `--top-p 0.95`, `--top-k 40`, `--min-p 0.01`

## Historical vLLM DFlash experiment (not deployed)

**Model**: `AEON-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-Multimodal-NVFP4-MTP-XS` (~90GB)
**Image**: `ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v4`
**Decode**: speculative decoding via DFlash (15 draft tokens)
The old StatefulSet manifest was removed when GLM-5.3 became the active
deployment. These settings are reference material only, not a GitOps rollback
path.

### vLLM Tuning Notes (for future use)
- `--gpu-memory-utilization 0.60` (conservative for unified memory buffer cache)
- `--enable-prefix-caching` — free throughput for repeated system prompts
- `--enable-chunked-prefill` — better TTFT
- `--speculative-config '{"method":"dflash","model":"...","num_speculative_tokens":15}'`
- `--block-size 32` — PagedAttention block size
- `--attention-backend flash_attn`
- `MMProcessor` cache on `/dev/shm` (`--mm-processor-cache-type shm`)
- `VLLM_CPU_KV_TRANSFER_CHUNK_SIZE=16`, `VLLM_BLOCK_SIZE=32` — CPU/KV cache tuning

## Historical comparison: retired alternatives

| | Historical vLLM DFlash | llama.cpp Q4 (not deployed) |
|---|---|---|
| Model | Qwen3.6-27B NVFP4-MTP-XS | Qwen3-Coder-Next UD-Q4_K_XL |
| Model size | ~90GB | ~46GB |
| Decode speed | ~40+ tok/s (speculative) | ~33 tok/s |
| Free memory | ~38GB | ~82GB |
| Context | 200K | 131K |
| Parallel requests | 64/replica | 1 |
| Tool calling | Native auto-tool-choice | Jinja templates |
| Status | No current manifest | No current manifest |
| Speculative decode | DFlash (15 tokens) | None |

## Quantization Options for DGX Spark

### Available for Qwen3-Coder-Next
| Format | Size | vLLM | llama.cpp | Notes |
|--------|------|------|-----------|-------|
| FP8 | ~85GB | Yes | No | Best quality, native Blackwell acceleration |
| FP8-Dynamic (Unsloth) | ~85GB | Yes | No | 25%+ throughput boost claimed |
| Q4_K_XL GGUF (Unsloth) | ~46GB | No | Yes | Best for memory constrained |
| Q3 GGUF | ~30GB | No | Yes | Lower quality, smallest size |

### Broader Quantization Landscape
- **NVFP4**: Native Blackwell FP4. Best perf/byte but needs SM_121-compiled vLLM (`avarok/vllm-nvfp4-gb10-sm120:v14`). Pre-quantized models: `nvidia/Qwen3-30B-A3B-NVFP4`, `nvidia/DeepSeek-R1-NVFP4`
- **AWQ INT4** (Marlin): Best general vLLM 4-bit. ~741 tok/s throughput with Marlin kernel. No AWQ version of Qwen3-Coder-Next exists yet.
- **GPTQ INT4** (Marlin): Slightly behind AWQ quality. ~712 tok/s.
- **BitsAndBytes 4-bit**: On-the-fly quantization (no pre-quantized checkpoint needed) but ~168 tok/s (slow).

### What Fits in 128GB (model weights only)
| Model | FP16 | FP8 | INT4 | NVFP4 |
|-------|------|-----|------|-------|
| 70B | 140GB (no) | 70GB | 35GB | 40GB |
| 80B MoE (Qwen3-CN) | ~160GB (no) | ~85GB | ~46GB | ~50GB |
| 405B | 810GB (no) | 405GB (no) | ~100GB (barely) | ~115GB (barely) |

## DGX Spark Gotchas

1. **Unified memory ≠ VRAM**: `--fit on` in llama.cpp and `--gpu-memory-utilization` in vLLM miscalculate available memory because they see the GPU's allocation separately from total unified pool.
2. **ARM64 images required**: Standard x86_64 Docker images won't work. Need ARM64+CUDA builds.
3. **SM_121 kernels**: Stock vLLM is compiled for SM_100 (Hopper). NVFP4 MoE kernels need SM_120+ specific builds.
4. **No official ARM64+CUDA llama.cpp images**: `ghcr.io/ggml-org/llama.cpp:server-cuda` is amd64 only. Use `ghcr.io/ardge-labs/llama-cpp-dgx-spark:server` or build your own.
5. **Qwen3-Coder-Next is Gated DeltaNet**: Not standard Transformer or Mamba. Requires llama.cpp b7186+ with Feb 4, 2026 key_gdiff fix (PR #19324).
6. **Buffer cache on unified memory**: vLLM may OOM even when memory appears available. Flush with `echo 3 > /proc/sys/vm/drop_caches`.
7. **llama.cpp ~40% slower than vLLM**: Known ARM CPU performance issue (GitHub #19345, #19386). Ongoing.

## Docker Images

| Image | Purpose | Architecture |
|-------|---------|-------------|
| `scitrera/dgx-spark-vllm:0.15.1-t5` | vLLM for DGX Spark | ARM64+CUDA |
| `ghcr.io/ardge-labs/llama-cpp-dgx-spark:server` | llama.cpp for DGX Spark | ARM64+CUDA 13.0+SM_121 |
| `avarok/vllm-nvfp4-gb10-sm120:v14` | vLLM with NVFP4 for Blackwell | ARM64+CUDA |

## OpenCode Configuration

For Bhaiya-managed workspaces, the generated config lives at
`~/.config/opencode/config.json` and stays on the CLIProxy route:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "cliproxy/vllm/GLM-5.3-Flash",
  "provider": {
    "cliproxy": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://cliproxy.cliproxy.svc.cluster.local:8317/v1",
        "apiKey": "{env:OPENAI_API_KEY}"
      },
      "models": {
        "vllm/GLM-5.3-Flash": {
          "name": "vllm/GLM-5.3-Flash",
          "reasoning": true,
          "limit": { "context": 1000000, "output": 0 }
        }
      }
    }
  }
}
```

Tailscale MagicDNS hostnames:
- `stpetersburg-vllm` → active vLLM GLM-5.3-Flash EXL3 server (port 80 → 8000)
- There is no current `stpetersburg-llama-cpp` Service; the llama.cpp route
  described above is historical reference material only.

## References

- [Unsloth Qwen3-Coder-Next Guide](https://unsloth.ai/docs/models/qwen3-coder-next)
- [NVIDIA DGX Spark Hardware Docs](https://docs.nvidia.com/dgx/dgx-spark/hardware.html)
- [vLLM Quantization Docs](https://docs.vllm.ai/en/latest/features/quantization/)
- [MiaAI-Lab GLM-5.3-Flash EXL3 recipe](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks)
- [IncoAI GLM-5.3-Flash DFlash2](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2)
- [llama.cpp Qwen3-Next PR #16095](https://github.com/ggml-org/llama.cpp/pull/16095)
- [key_gdiff Fix PR #19324](https://github.com/ggml-org/llama.cpp/pull/19324)
- [ardge-labs DGX Spark images](https://github.com/ardge-labs/llama-cpp-dgx-spark)
- [Avarok NVFP4 Blog](https://blog.avarok.net/nvfp4-w4a4-moe-inference-on-nvidia-blackwell-gb10-1a83e85d0f9e)
- [NVIDIA NVFP4 Blog](https://developer.nvidia.com/blog/introducing-nvfp4-for-efficient-and-accurate-low-precision-inference/)
