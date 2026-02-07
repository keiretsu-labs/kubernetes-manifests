# 3x DGX Spark (GB10) Distributed Inference Research

> Can 3x NVIDIA DGX Spark (GB10) nodes run distributed inference with TensorRT-LLM + vLLM and full quantization support?

---

## TL;DR: Yes, theoretically possible. Practically painful today.

**The short answer:** 3x DGX Spark gives you 384 GB of unified memory and 3 PFLOPS of FP4 compute, connected via 200GbE RoCE. You can run Llama 405B at FP4/INT4 across 3 nodes with ~181 GB headroom for KV cache. TensorRT-LLM + vLLM both support multi-node inference via NCCL over Ethernet. Quantization (FP8, FP4, INT4, AWQ, GPTQ) is supported on Blackwell. **But**: the software stack is beta, FP4 support in vLLM is immature, GPUDirect RDMA doesn't work on GB10, and token generation will be slow (~2-8 tok/s for 405B). 3-node clustering has no official NVIDIA support (only 2-node is documented).

---

## 1. Hardware: NVIDIA DGX Spark / GB10 Superchip

### Per-Node Specifications

| Spec | Value |
|------|-------|
| **GPU Architecture** | Blackwell (SM120, compute capability 12.1) |
| **CPU** | 20-core ARMv9 (MediaTek, NOT Grace) |
| **CUDA Cores** | 6,144 (48 SMs x 128 cores/SM) |
| **Tensor Cores** | 192 (5th gen, 4 per SM) |
| **RT Cores** | 48 |
| **Clock** | Base 2418 MHz / Boost 2525 MHz |
| **Unified Memory** | 128 GB LPDDR5X (shared CPU+GPU) |
| **Memory Bandwidth** | 273 GB/s (datasheet), 300 GB/s peak (Hot Chips) |
| **Internal Interconnect** | NVLink C2C ~600 GB/s aggregate (CPU die <-> GPU die) |
| **Networking** | ConnectX-7, 2x QSFP56, 200GbE **Ethernet only** |
| **Power** | ~250W (desktop form factor) |

### Measured Compute Performance (dense, from mmapeak benchmarks)

| Precision | TFLOPS (dense) | TFLOPS (sparse) |
|-----------|---------------|-----------------|
| **FP4 (NVFP4)** | ~427 | ~993 (marketed as "1 PFLOPS") |
| **FP8** | ~213-215 | ~427 |
| **FP16/BF16** | ~212-213 | ~425 |
| **INT8** | ~215 | ~430 |
| **TF32** | ~53 | - |
| **FP32** | ~31 | - |

### 3x Node Aggregate

| Metric | 3x DGX Spark |
|--------|-------------|
| **Total Memory** | 384 GB |
| **Total FP4 Compute (dense)** | ~1,281 TFLOPS |
| **Total FP8 Compute** | ~645 TFLOPS |
| **Total Memory Bandwidth** | 819 GB/s (273 x 3) |
| **Inter-node Bandwidth** | 200 Gbps (~24 GB/s) per link via RoCE |

---

## 2. Networking: ConnectX-7 200GbE Deep Dive

### The Dual-x4 Architecture (from ServeTheHome)

The GB10 SoC can only provide PCIe Gen5 x4 per device. NVIDIA's workaround: the ConnectX-7 is connected via **two separate PCIe Gen5 x4 links** (each ~100 Gbps). Each physical QSFP port presents as **two logical network interfaces**. You MUST drive both halves simultaneously to achieve 200 Gbps from one port.

### Achievable Bandwidth

| Configuration | Bandwidth |
|--------------|-----------|
| Single stream iperf3 | ~30 Gbps |
| 16 parallel streams | ~106 Gbps |
| Dual-half + jumbo frames (60+ streams) | ~160-198 Gbps |
| **RoCE (ib_write_bw)** | **~185-190 Gbps** |
| NCCL all_reduce (RoCE, 4 nodes) | **~190 Gbps (~23.76 GB/s)** |
| NCCL over TCP Sockets (broken default) | ~16 Gbps (~2 GB/s) |

### Critical Configuration Issue

**The default DGX OS ships with `/etc/nccl.conf` containing `NCCL_IB_DISABLE=1`**, forcing NCCL into Socket mode (~2 GB/s). You **must** remove or edit this to enable RoCE/IB transport. Required env vars:
- `NCCL_SOCKET_IFNAME=enp1s0f1np1`
- `UCX_NET_DEVICES=enp1s0f1np1`

### GPUDirect RDMA: NOT SUPPORTED

GPUDirect RDMA is architecturally impossible on the GB10. The unified memory architecture means there's no discrete GPU memory with PCIe BAR for the NIC to write to directly. The `nvidia-peermem` kernel module cannot load.

**Workaround:** `cudaHostAlloc()` + unified virtual addressing still delivers ~176 Gbps (~22 GB/s) practical throughput because the GPU can access host-allocated RDMA buffers through the C2C interconnect without explicit copies.

### 3-Node Topology Options

| Topology | Bandwidth | Notes |
|----------|-----------|-------|
| **2-node direct cable** | ~190 Gbps | Official NVIDIA support. No switch needed. |
| **3-node switchless mesh** | ~60 Gbps | Community hack (custom NCCL plugin, ~1500 lines). Triangle of DAC cables. |
| **3-node via switch** | ~190 Gbps per link | Requires 200GbE switch. MikroTik CRS812 (~$1.5-2K) confirmed working. |

### 200 GbE vs NVLink Comparison

| Metric | 200 GbE (RoCE) | NVLink C2C (internal) | NVLink 5th Gen (datacenter) |
|--------|----------------|----------------------|----------------------------|
| Bandwidth | ~24 GB/s | 600 GB/s | 1,800 GB/s |
| Latency | ~7-10 us | sub-us | sub-us |
| Ratio | 1x | 25x | 75x |

---

## 3. TensorRT-LLM on GB10

### Platform Support

- **ARM/Blackwell:** TensorRT-LLM supports GB10 (SM120). Initially had kernel issues but SM120 support was merged (PR #7937).
- **DGX Spark status:** **Beta**. Only single-node configurations officially validated.
- **Known issues on SM120:**
  - `TRTLLMGenFusedMoE` did not support SM120 (affects MoE models like DeepSeek, Mixtral)
  - FP4 GEMM runtime errors on SM120 (FlashInfer/CUTLASS fallback chain failures)
  - NVFP4 KV cache not yet supported for SM120 in trtllm-gen
  - GPU memory reported as ~119 GB instead of 128 GB

### Quantization Support

| Method | Status on Blackwell | Notes |
|--------|-------------------|-------|
| **NVFP4** | Supported | <1% quality degradation vs FP8. Native Blackwell format. |
| **FP8** | Supported | Default recommended quantization. |
| **INT8** | Supported | SmoothQuant, weight-only, and weight+activation. |
| **INT4 (AWQ)** | Supported | Better than NVFP4 in current vLLM builds on GB10. |
| **INT4 (GPTQ)** | Supported | - |
| **FP16/BF16** | Supported | Full precision baseline. |

### Multi-Node Distributed Inference

- **Communication:** MPI (CPU) + NCCL v2.28.3 (GPU)
- **Parallelism modes:** Tensor Parallel, Pipeline Parallel, Expert Parallel (for MoE)
- **Disaggregated serving:** Prefill/decode separation with KV cache transfer via UCX or NIXL
- **Expert Parallelism:** Native support for DeepSeek V3/R1, Mixtral, Qwen3-MoE
- **Max single-node model:** ~200B parameters (engine building requires more memory than deployment)

### Engine Building Limitation

Building TRT-LLM engines on the GB10 requires significantly more memory than deployment. A 49B FP8 model (53 GB) failed to compile on a single node. **Workaround:** Use the TensorRT Optimizer to create NVFP4 quantized models externally, then deploy with TRT-LLM.

---

## 4. vLLM Distributed Inference

### Multi-Node Support

- **Yes, supported** via Ray cluster
- **Communication:** NCCL for GPU collective ops, Ray for orchestration
- **ARM/aarch64:** Supported (ARM64 with NEON). Tested on AWS Graviton3.
- **NVIDIA has official DGX Spark playbooks** for vLLM Ray clusters

### Parallelism Strategy Recommendation

> **For slow interconnects (like 200GbE):** Use Pipeline Parallelism across nodes, Tensor Parallelism within nodes.
>
> **For fast interconnects (NVLink/IB):** Use Tensor Parallelism across nodes.

Since GB10 has 1 GPU per node, the configuration for 3 nodes would be:
- `--tensor-parallel-size 1 --pipeline-parallel-size 3`

Or if using tensor parallel across nodes (works but suboptimal over 200 GbE):
- `--tensor-parallel-size 3`

### Quantization Support in vLLM

13+ quantization methods supported:
- AWQ, GPTQ, SqueezeLLM, FP8 (W8A8), BitsAndBytes
- AQLM, DeepSpeedFP, GGUF, HQQ, Marlin
- LLM Compressor, ModelOpt, Quantized KV Cache, TorchAO

### FP4/NVFP4 on GB10: Immature

**Critical finding:** FP4/NVFP4 is **not properly utilized** in current vLLM builds on DGX Spark. Users report performance loss when using NVFP4 quantized models compared to AWQ 4-bit. The vLLM codebase detects GB10 is NOT SM100 (B200), tries to fall back through FlashInfer -> CUTLASS FP4, but both paths have issues on SM120.

**Recommendation:** Use AWQ INT4 quantization instead of NVFP4 for now on GB10.

### Ethernet vs InfiniBand: Surprisingly Close

Independent benchmarks on Azure A100 clusters (tp=8, pp=2):
- **No InfiniBand:** 0.646 req/s -> 1.578 req/s (QPS 0.1 to unbounded)
- **With InfiniBand:** 0.651 req/s -> 1.577 req/s
- **Difference: <1%** for pipeline parallel workloads

Similarly, GH200 testing at 800 Gbps Ethernet showed no improvement over 400 Gbps for pipeline parallel - the bottleneck is scheduling/synchronization, not raw network bandwidth.

**Key insight:** For pipeline parallel (which is what you'd use on 3x GB10), 200 GbE is not the bottleneck. Memory bandwidth (273 GB/s) is.

---

## 5. Model Sizing: What Fits on 3x GB10?

### Memory Budget

| Component | Available |
|-----------|-----------|
| Total unified memory | 384 GB (3 x 128 GB) |
| Usable GPU memory (reported) | ~359 GB (3 x ~119.7 GB) |
| OS/system overhead | ~25 GB |
| Target for model + KV cache | ~340-360 GB |

### Model Weight Sizes

| Model | FP16 | FP8 | INT4/FP4 | Fits in 384 GB? |
|-------|------|-----|----------|----------------|
| **Llama 3.1 8B** | 16 GB | 8 GB | 4 GB | 1 node easily |
| **Llama 3.1 70B** | 140 GB | 70 GB | 35 GB | 1 node at FP4 |
| **Qwen3 235B** | 470 GB | 235 GB | ~118 GB | 2+ nodes at FP4 (demonstrated) |
| **Llama 3.1 405B** | 810 GB | 405 GB | **~203 GB** | **3 nodes at FP4/INT4** |
| **DeepSeek V3/R1 (671B MoE)** | 1.3 TB | ~671 GB | **~336 GB** | Barely at FP4 (tight) |
| **Qwen3-Coder-Next-FP8** | - | depends on size | - | Need model size info |

### Llama 405B on 3x GB10: The Math

```
Model weights at INT4:    ~203 GB
Available memory:         ~360 GB
Remaining for KV cache:   ~157 GB

KV cache per token (Llama 405B):
  - 126 layers, hidden_dim 16384, 128 heads, 8 KV heads (GQA)
  - Per token: 2 * 126 * (16384/128 * 8) * 2 bytes (FP16) = ~2.58 MB
  - At FP8 KV cache: ~1.29 MB per token
  - 157 GB / 1.29 MB ≈ ~121K tokens of context

Conclusion: 405B INT4 on 3 nodes can support ~121K context at FP8 KV cache.
```

### Token Generation Speed Estimates (Memory-Bound Decode)

The formula: `tok/s ≈ memory_bandwidth / model_bytes_per_token_step`

For pipeline parallel across 3 nodes, each node processes 1/3 of the layers:
- Per-node model shard: ~68 GB (405B at INT4, split across 3)
- Per-node bandwidth: 273 GB/s
- Theoretical max: 273/68 ≈ **4 tok/s** per node
- Pipeline parallel adds bubble overhead: expect **~2-5 tok/s** for 405B

### Actual Benchmarks (Closest Available)

| Config | Model | Prompt tok/s | Generate tok/s |
|--------|-------|-------------|----------------|
| 2x Spark, TRT-LLM NVFP4 | Qwen3 235B | 23,477 | 11.73 |
| 1x Spark, llama.cpp | 120B model | 1,723 | 38.55 |
| 2x Spark, vLLM INT4 | 405B | - | testing only (max-model-len 256) |
| 1x Spark, vLLM | Llama 3.1 8B | 10,257 | ~924 |

---

## 6. The Software Stack

```
User / API
   |
Inference Server (vLLM + Ray cluster)
   |
Execution Engine (TensorRT-LLM backend)
   |
Communication (NCCL over RoCE, MPI for control)
   |
Hardware (3x GB10 / ConnectX-7 200GbE)
```

### What Works Today

1. **vLLM + Ray** multi-node cluster on DGX Spark (official NVIDIA playbooks exist)
2. **TensorRT-LLM** as backend for vLLM (NVIDIA maintains integration)
3. **AWQ INT4** quantization on GB10 (more reliable than NVFP4 currently)
4. **FP8** quantization (fully supported on Blackwell)
5. **NCCL over RoCE** at ~190 Gbps (with proper configuration)
6. **Pipeline Parallel** across nodes (recommended for 200 GbE)
7. **2-node clustering** (officially documented and supported)

### What Doesn't Work / Is Broken

1. **3-node clustering** - No official support. Community has a custom NCCL plugin for 3-node mesh.
2. **NVFP4 in vLLM** - Broken on SM120. Use AWQ INT4 instead.
3. **GPUDirect RDMA** - Architecturally impossible on GB10.
4. **FusedMoE on SM120** - Needed for DeepSeek/Mixtral. Fix merged but may not be in stable releases.
5. **NVFP4 KV cache on SM120** - Not yet supported in trtllm-gen.
6. **405B on 2x Spark** - "Testing only" (max-model-len 256, max-num-seqs 1).
7. **Engine building for large models** - OOM on GB10 for models >49B. Must build externally.

---

## 7. Feasibility Assessment

### Can you run 3x DGX Spark with TRT-LLM + vLLM for distributed inference?

| Aspect | Verdict | Details |
|--------|---------|---------|
| **Hardware capable?** | YES | 384 GB memory, 200 GbE RoCE networking |
| **Software supports multi-node?** | YES (2-node official, 3-node community) | vLLM + Ray + NCCL over RoCE |
| **TRT-LLM works on GB10?** | PARTIALLY (beta) | SM120 kernel issues being resolved |
| **Full quantization support?** | MOSTLY | FP8, INT8, AWQ INT4 work. NVFP4 broken in vLLM. |
| **405B model fits?** | YES at INT4 | ~203 GB weights, ~157 GB for KV cache |
| **Usable generation speed?** | MARGINAL | Estimate 2-5 tok/s for 405B (memory-bandwidth bound) |
| **Production ready?** | NO | Beta software, 3-node not official, NVFP4 broken |
| **Developer experimentation?** | YES | NVIDIA's stated intended use case |

### Recommendation

**For 3x DGX Spark today:**

1. **Best practical config:** Run Llama 3.1 70B or Qwen 72B at FP8 on a **single node** (70-72 GB, fits comfortably in 128 GB). You'll get ~20-40 tok/s generation. Use the other 2 nodes for different models or redundancy.

2. **If you must run 405B:** Use AWQ INT4 quantization (not NVFP4), pipeline parallel across 3 nodes. Expect ~2-5 tok/s generation. Need a 200 GbE switch (MikroTik CRS812, ~$1.5K). Will require custom work for 3-node NCCL setup.

3. **Wait for:** NVFP4 vLLM fixes on SM120, official 3-node support, NVFP4 KV cache support. These would significantly improve the experience.

4. **For Qwen3-Coder-Next-FP8** (from your vllm.yaml): If this is a ~70B-class model at FP8, it fits on a single Spark. If it's larger (235B+), you'd need 2-3 nodes with pipeline parallel.

---

## 8. Key Numbers to Remember

| Metric | Value |
|--------|-------|
| Per-node memory | 128 GB (119.7 GB usable) |
| Per-node memory bandwidth | 273 GB/s |
| Per-node FP4 dense compute | 427 TFLOPS |
| Inter-node bandwidth (RoCE) | ~24 GB/s (~190 Gbps) |
| Inter-node bandwidth (TCP, broken default) | ~2 GB/s |
| Internal C2C bandwidth | ~600 GB/s |
| 405B at INT4 | ~203 GB weights |
| 405B at FP8 | ~405 GB weights (doesn't fit 3 nodes) |
| KV cache per token (405B, FP16) | ~2.58 MB |
| 3 nodes total memory | 384 GB |
| 200 GbE switch cost | ~$1,500-2,000 (MikroTik CRS812) |

---

## Sources

- NVIDIA DGX Spark Hardware Overview: https://docs.nvidia.com/dgx/dgx-spark/hardware.html
- NVIDIA DGX Spark Clustering Guide: https://docs.nvidia.com/dgx/dgx-spark/spark-clustering.html
- NVIDIA Developer Blog - DGX Spark Performance: https://developer.nvidia.com/blog/how-nvidia-dgx-sparks-performance-enables-intensive-ai-tasks/
- ServeTheHome - GB10 ConnectX-7 Networking: https://www.servethehome.com/the-nvidia-gb10-connectx-7-200gbe-networking-is-really-different/
- NVIDIA Developer Forums - Detailed Compute Performance Metrics: https://forums.developer.nvidia.com/t/detailed-compute-performance-metrics-for-dgx-spark/351993
- NVIDIA Developer Forums - GPUDirect RDMA on DGX Spark: https://forums.developer.nvidia.com/t/gpu-direct-rdma-not-working-on-dgx-spark-systems-nvidia-peermem-module-fails-to-load/349837
- NVIDIA Developer Forums - 4-Node CRS812 Clustering: https://forums.developer.nvidia.com/t/dgx-spark-gb10-connectx-7-200gbe-via-mikrotik-crs812-qsfp-dd-2xqsfp56-breakout/357162
- NVIDIA DGX Spark Playbooks (vLLM Ray Cluster): https://build.nvidia.com/spark/vllm/stacked-sparks
- NVIDIA TensorRT-LLM GitHub: https://github.com/NVIDIA/TensorRT-LLM
- vLLM Distributed Serving Docs: https://docs.vllm.ai/en/v0.8.1/serving/distributed_serving.html
- LMSYS DGX Spark In-Depth Review: https://lmsys.org/blog/2025-10-13-nvidia-dgx-spark/
- Hardware Corner - DGX Spark Benchmarks: https://www.hardware-corner.net/first-dgx-spark-llm-benchmarks/
- ChipLog - GB10 SoC Analysis: https://www.chiplog.io/p/analysis-of-nvidia-dgx-sparks-gb10
- HMC Tech - GB10 Full Specs: https://hmc-tech.com/gpu/nvidia-gb10
- vLLM Blog - Distributed Inference: https://blog.vllm.ai/2025/02/17/distributed-inference.html
- vLLM Blog - Large Scale Serving on GB200: https://blog.vllm.ai/2026/02/03/dsr1-gb200-part1.html
- TensorRT-LLM Expert Parallelism Docs: https://nvidia.github.io/TensorRT-LLM/advanced/expert-parallelism.html
- TensorRT-LLM Disaggregated Serving: https://nvidia.github.io/TensorRT-LLM/blogs/tech_blog/blog5_Disaggregated_Serving_in_TensorRT-LLM.html
- GitHub Issue - NVFP4 on 2x Spark with vLLM: https://github.com/vllm-project/vllm/issues/30163
- GitHub Issue - TRT-LLM SM120 Support: https://github.com/NVIDIA/TensorRT-LLM/issues/8474
