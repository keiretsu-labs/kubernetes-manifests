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
| KV cache | FP8; `TF_GLM_CACHE_GIB=2` |
| Memory reserve | `TENSORFOLD_MEMORY_RESERVE_GIB=6.5` |
| Parallel requests | 1 (`--parallel 1`) |
| Per-rank pod resources | 96Gi request / 112Gi limit; one GPU |
| NCCL/RoCE | `eth2`, `mlx5_1`, GID 3; TensorFold small gathers use RoCE |

DFlash2 is intentionally not used: its included license is CC BY-NC-ND and
restricts commercial use. This 1M-context recovery qualification keeps
`PARALLEL=1` with the checkpoint's MTP head and a 2GiB KV pool. Do not reduce
the reserve below 6GiB; increase parallelism or the cache pool only after
measured memory qualification.

The MemAvailable preflight init container remains enabled, and TensorFold's
own pre-allocation check refuses profiles that do not fit its reserve. The
LeaderWorkerSet explicitly uses `maxSurge: 0` and `maxUnavailable: 1`, so old
ranks stop before the replacement group starts; never change it to an
overlapping rollout on these shared-memory nodes.

### Qualification record

The earlier `MemAvailable` samples (`417,300 kB` on `spark-0` and `1,691,688 kB`
on `spark-1`) were taken while the old vLLM model was loaded and are not current
idle readings. PR #3354's 32GiB reserve and PR #3357's 14.5GiB reserve both
failed before loading weights with a zero-token fitting window; the #3357
preflight measured `MemAvailable=101,039,676 KiB` (~96.36GiB) on rank 0. The
pinned TensorFold v0.6.0 CUDA capacity code uses `MemAvailable - reserve` on
unified-memory GPUs and sets the fitting window to zero when estimated resident
weights plus staging exceed that budget, before context sizing. The reported
rank-0 startup estimate is ~88.09GiB: reserve 14.5GiB left only ~81.86GiB,
whereas reserve 6.5GiB gives ~89.86GiB (~1.77GiB estimate headroom). This
iteration keeps context at 1,048,576, `PARALLEL=1`, FP8 KV, and a 2GiB pool to
limit the subsequent cache geometry. TensorFold's CUDA allocations on Sparks
are not capped by the container memory limit; the 96Gi request / 112Gi limit
does not raise its startup budget. The current scheduler request totals include
the 96Gi rank pods: 104,995Mi on `spark-0` and 106,379Mi on `spark-1`, leaving
about 3.1Gi and 3.8Gi of allocatable memory. No page-cache drop or unrelated
workload change is included. This profile remains unqualified until both ranks
load and post-rollout memory and completion tests succeed.

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

## Prefill tuning (proposed; needs a coordinated restart of both ranks)

Measured against `vllm-0:8888` on 2026-10-01 with the profile above (no `TF_GLM_HC_SPLIT`,
`TF_GLM_PREFILL_OVERLAP` or `TF_GLM_KDA_CHUNKED`, which are off by default in TensorFold v0.6.0):

| Prompt | Prefill rate (server-side) |
| ---: | ---: |
| 20k | 1,335 tok/s |
| 50k | 1,309 tok/s |
| 100k | 1,275 tok/s |
| 987k | ~797 tok/s (1,238 s) |

The upstream recipe reports ~1,950 tok/s at 8-65k and ~1,015 tok/s at 981k with `SPLIT=1`
(`TF_GLM_HC_SPLIT=1`, `TF_GLM_PREFILL_OVERLAP=2`) and `KDA_CHUNKED=1`; its own patch notes give
~1,270 -> ~1,730 tok/s at 50k for SPLIT and a further ~8-10% for KDA chunking. These three variables
are what this change adds to both ranks. Expected gain: roughly +25-35% prefill, i.e. a ~987k prompt
in about 15-16 min instead of ~20.6 min (an estimate; not measured on this cluster).

Risks: the startup estimate has only ~0.14GiB headroom (88.07GiB within 88.21GiB on rank 0), and the
split/overlap and chunked-KDA paths may need extra scratch, in which case TensorFold refuses to start
before loading weights (no data loss, but both ranks crash-loop until rolled back). `KDA_CHUNKED` is
close to, not bit-identical with, the serial kernel (prompt arithmetic differs). Both ranks must
carry identical values. Applying it restarts both GLM pods (zero-surge LWS rollout, ~6.5 min load).
Do not merge without approval to restart.

Rollback: revert this PR; Flux restores the previous env and the pods restart again.
