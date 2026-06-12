# AI Inference on DGX Spark (GB10 Blackwell)

## Hardware: NVIDIA DGX Spark / SM120 / GB10

- **GPU**: NVIDIA GB10 Grace Blackwell Superchip (SM_121, compute capability 12.1)
- **Memory**: 128GB LPDDR5X **unified** (shared between CPU and GPU — no dedicated VRAM)
- **Bandwidth**: ~273 GB/s (LPDDR5X), ~600 GB/s NVLink-C2C between CPU/GPU dies
- **Tensor Cores**: 192x 5th-gen (native FP4/FP6/FP8 support)
- **FP4 Peak**: ~1 PFLOP (1000 TOPS)
- **CPU**: 10x Cortex-X925 + 10x Cortex-A725 (ARM64)
- **CUDA**: Requires CUDA 13.0+
- **OS**: Talos Linux v1.12.2

## Current Setup: llama.cpp (Q4 GGUF)

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

## Previous Setup: vLLM (DFlash) — currently disabled (replicas: 0)

**Model**: `AEON-7/Qwen3.6-27B-AEON-Ultimate-Uncensored-Multimodal-NVFP4-MTP-XS` (~90GB)
**Image**: `ghcr.io/aeon-7/vllm-aeon-ultimate-dflash:qwen36-v4`
**Decode**: speculative decoding via DFlash (15 draft tokens)
**Status**: `replicas: 0` — both DGX Spark GPUs are claimed by the DeepSeek-V4-Flash
TP=2 instance (`dsv4.yaml`). Kept in-repo for rollback.

Config lives in `vllm.yaml` but the StatefulSet is scaled to zero.

### vLLM Tuning Notes (for future use)
- `--gpu-memory-utilization 0.60` (conservative for unified memory buffer cache)
- `--enable-prefix-caching` — free throughput for repeated system prompts
- `--enable-chunked-prefill` — better TTFT
- `--speculative-config '{"method":"dflash","model":"...","num_speculative_tokens":15}'`
- `--block-size 32` — PagedAttention block size
- `--attention-backend flash_attn`
- `MMProcessor` cache on `/dev/shm` (`--mm-processor-cache-type shm`)
- `VLLM_CPU_KV_TRANSFER_CHUNK_SIZE=16`, `VLLM_BLOCK_SIZE=32` — CPU/KV cache tuning

## Comparison: vLLM (DFlash, disabled) vs llama.cpp (Q4, active)

| | vLLM DFlash (disabled) | llama.cpp Q4 (active) |
|---|---|---|
| Model | Qwen3.6-27B NVFP4-MTP-XS | Qwen3-Coder-Next UD-Q4_K_XL |
| Model size | ~90GB | ~46GB |
| Decode speed | ~40+ tok/s (speculative) | ~33 tok/s |
| Free memory | ~38GB | ~82GB |
| Context | 200K | 131K |
| Parallel requests | 64/replica | 1 |
| Tool calling | Native auto-tool-choice | Jinja templates |
| Status | `replicas: 0` (disabled) | Active |
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

Config lives at `~/.config/opencode/config.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llama-cpp/Qwen3-Coder-Next",
  "provider": {
    "llama-cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://stpetersburg-llama-cpp/v1"
      },
      "models": {
        "Qwen3-Coder-Next": {
          "name": "Qwen3-Coder-Next",
          "limit": { "context": 131072, "output": 16384 }
        }
      }
    }
  }
}
```

Tailscale MagicDNS hostnames:
- `stpetersburg-llama-cpp` → llama.cpp server (port 80 → 8000)
- `stpetersburg-vllm` → vLLM server (port 80 → 8000) [currently disabled]

## References

- [Unsloth Qwen3-Coder-Next Guide](https://unsloth.ai/docs/models/qwen3-coder-next)
- [NVIDIA DGX Spark Hardware Docs](https://docs.nvidia.com/dgx/dgx-spark/hardware.html)
- [vLLM Quantization Docs](https://docs.vllm.ai/en/latest/features/quantization/)
- [llama.cpp Qwen3-Next PR #16095](https://github.com/ggml-org/llama.cpp/pull/16095)
- [key_gdiff Fix PR #19324](https://github.com/ggml-org/llama.cpp/pull/19324)
- [ardge-labs DGX Spark images](https://github.com/ardge-labs/llama-cpp-dgx-spark)
- [Avarok NVFP4 Blog](https://blog.avarok.net/nvfp4-w4a4-moe-inference-on-nvidia-blackwell-gb10-1a83e85d0f9e)
- [NVIDIA NVFP4 Blog](https://developer.nvidia.com/blog/introducing-nvfp4-for-efficient-and-accurate-low-precision-inference/)
