# AI inference on 2× NVIDIA DGX Spark

## Active deployment: GLM-5.3-Flash EXL3/TR3 with TensorFold

- **Model:** `Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw`
- **Cached revision:** `25a44fdbf16862a46b7cc9921142c6c81350af2f`
- **TensorFold recipe revision:** `9eaebb7c4e96d983dcd538e18624622ba5b820a8`
- **Runtime:** TensorFold v0.6.0, image pinned by digest:
  `ghcr.io/miaai-lab/glm-5.3-flash-exl3-2x-dgx-sparks-tensorfold@sha256:22789f0cb3dc308f0b2ce52a33961b88bd624af1725e91e8aba0a74a671bb969`
- **Topology:** the existing `vllm` LeaderWorkerSet identity is retained for an
  in-place update; rank 0/API runs on `spark-0`, rank 1 on `spark-1`, TP=2 over
  the existing `eth2` / `mlx5_1` RoCE link with rendezvous port `29551`.
- **Serving ID:** `GLM-5.3-Flash-EXL3` (client-facing CLIProxy/LiteLLM IDs stay
  `vllm/GLM-5.3-Flash-EXL3`).
- **API:** `model-serving.ai:8888`; the cross-cluster mesh Service remains
  `model-serving-mesh:80` and existing egress aliases remain unchanged.

The upstream recipe pins a newer Hugging Face revision than the cached
checkpoint. Before rollout, the existing model files and their checksum index
were verified on both PVCs; the cache and recipe revisions resolve to the same
`SHA256SUMS` object. Startup validates the cached marker, model files, and
`tensorfold info` in offline mode. It does not download weights, use a Hugging
Face token, or load DFlash2.

## First shared-cluster profile

| Setting | Initial value |
| --- | --- |
| `DRAFTER` | `mtp` (`--drafter none`); one concurrent stream |
| `CONTEXT` | `1048576` (`--context 1048576`) |
| Vision | disabled; language-only |
| KV cache | FP8; `TF_GLM_CACHE_GIB=4` |
| Memory reserve | `TENSORFOLD_MEMORY_RESERVE_GIB=14.5` |
| Parallel requests | 1 (`--parallel 1`) |
| Per-rank pod resources | 96Gi request / 112Gi limit; one GPU |
| NCCL/RoCE | `eth2`, `mlx5_1`, GID 3; TensorFold small gathers use RoCE |

DFlash2 is intentionally not used: its included license is CC BY-NC-ND and
restricts commercial use. This first 1M-context qualification keeps
`PARALLEL=1` with the checkpoint's MTP head and a 4GiB KV pool. Increase
parallelism or the cache pool only after measured memory qualification.

The MemAvailable preflight init container remains enabled, and TensorFold's
own pre-allocation check refuses profiles that do not fit its reserve. The
LeaderWorkerSet explicitly uses `maxSurge: 0` and `maxUnavailable: 1`, so old
ranks stop before the replacement group starts; never change it to an
overlapping rollout on these shared-memory nodes.

### Qualification record

The earlier `MemAvailable` samples (`417,300 kB` on `spark-0` and `1,691,688 kB`
on `spark-1`) were taken while the old vLLM model was loaded and are not current
idle readings. The first TensorFold startup rejected context 32,768 with
`TENSORFOLD_MEMORY_RESERVE_GIB=32`, reporting a zero-token fitting window before
loading weights; no OOM was observed. This profile restores upstream's 14.5GiB
reserve and 1M context, while keeping `PARALLEL=1`, reducing the KV pool to
4GiB, and allowing up to 112GiB per rank. Current scheduler requests, including
the old 90Gi rank pods, are 98,851Mi on `spark-0` and 100,235Mi on `spark-1`;
the non-serving requests are 6,691Mi and 8,075Mi respectively. A 96Gi request
fits on both nodes after the zero-surge replacement, with about 3.1Gi and 3.8Gi
of allocatable memory left. No page-cache drop or unrelated workload change is
included. This is an unqualified recovery profile until both ranks load and
the post-rollout MemAvailable and completion tests are recorded.

The upstream recipe reports roughly 2–6 minutes to load weights after CUDA
kernels are cached, with a few more minutes for first-time kernel compilation.
This workload's startup probe allows up to 90 minutes for slower shared-node
starts. Record actual startup time and idle/peak `MemAvailable` for both Sparks
after the first qualification rollout before considering any larger profile.

## Monitoring and clients

- `/health` reports request, stream, and free-pool state; `/metrics` exports
  `tensorfold:*` request/token/cache metrics and `tensorfold_health:*` gauges.
- Probes and Gatus check `/health`, `/v1/models`, and `/metrics` on port 8888.
  The ServiceMonitor adds the deployed `model_name` and cluster labels for the
  TensorFold dashboard and alert rules.
- CLIProxy advertises a 1,048,576-token context window and LiteLLM caps input at
  the same profile limit. Keep all worker `OPENAI_BASE_URL` values unchanged.
- No St. Petersburg `sp-vllm` Envoy HTTPRoute is tracked in this repository;
  clients reach the model through the existing mesh and egress aliases.

## Rollback

The exact previous vLLM manifest and PVC references are recoverable from
commit `06448cde4c5699be6166340efbef06b3802352c9`:

```sh
git show 06448cde4c5699be6166340efbef06b3802352c9:kubernetes/apps/base/ai/ai/inference/model-serving.yaml
```

To roll back, open a GitOps revert PR for the swap commit (use
`git revert -m 1 <merge-commit>` only if the PR used a merge commit), run
`tools/check.sh stpetersburg`, and merge the revert after CI passes. Flux then
restores the vLLM LWS and existing services. Do not mutate the live cluster.
Both 200Gi PVCs and `/models/qwen38` are preserved; rollback does not download
or delete the checkpoint.

Rollback also uses the zero-surge full-rank restart and the old vLLM startup
checks. Expect endpoint downtime while ranks load; allow up to the existing
one-hour engine-ready timeout and 90-minute startup-probe window. Actual
TensorFold and rollback durations should be recorded after measured runs.
