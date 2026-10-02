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

To roll back to vLLM, open GitOps revert PRs (never mutate the live cluster),
run `tools/check.sh stpetersburg`, and merge after CI passes. Flux then
restores the vLLM LWS and existing services. Both 200Gi PVCs and
`/models/qwen38` are preserved; rollback does not download or delete the
checkpoint.

### Revert order

Undo the stack newest-first so each revert applies cleanly:

1. Revert #3370 (`3f1bd8fd`): TensorFold `TF_GLM_HC_SPLIT`, `TF_GLM_PREFILL_OVERLAP`
   and `TF_GLM_KDA_CHUNKED`. Stop here if only the prefill tuning regresses; this
   alone returns to the qualified 1M profile.
2. Revert #3358 (`755cab89`): iteration-2 fit profile (reserve 6.5GiB, 2GiB KV
   pool, `PARALLEL=1`, 96Gi request / 112Gi limit).
3. Revert #3357 (`0513bf3f`): 1M-context recovery profile.
4. Revert #3354 (`2e4a1509`): the 32,768-context / 32GiB-reserve backoff.
5. Revert the #3349 merge commit `b556050b` last, with
   `git revert -m 1 b556050b`. That restores the vLLM LWS and services.

PR #3350 (`a673f8eb`, TensorFold image digest bump) sits between #3349 and
#3354; it edits the image digest that #3349 introduced, so expect a conflict on that
line when reverting #3349 and resolve it by restoring the pre-#3349 state.

Every step restarts both GLM ranks (zero-surge LWS rollout; ~6.5 min TensorFold
load, and the old vLLM startup checks and up to 90-minute startup probe on the
final step). Expect endpoint downtime while ranks load, and get approval before
merging any revert.

## Prefill tuning (applied via #3370)

TensorFold v0.6.0 ships `TF_GLM_HC_SPLIT=0`, `TF_GLM_PREFILL_OVERLAP=0` and
`TF_GLM_KDA_CHUNKED=0` by default; the upstream recipe turns all three on. #3370
sets them on both ranks (they must match on both):

| Variable | Value | Effect |
| --- | --- | --- |
| `TF_GLM_HC_SPLIT` | `1` | Hyper-connection split path (upstream recipe default) |
| `TF_GLM_PREFILL_OVERLAP` | `2` | Prefill overlap, used together with the split (upstream recipe pairs `SPLIT=1` with overlap 2) |
| `TF_GLM_KDA_CHUNKED` | `1` | Chunked KDA prefill kernel; close to, not bit-identical with, the serial kernel |

Other TensorFold settings that stay off or unchanged: `TF_GLM_SHARED_PREFIX=0`
(a shared system prompt across different conversations is not reused),
`TF_GLM_CACHE_ENTRIES=8`, `TF_GLM_PREFILL_ROWS` at its 2048 default (a larger chunk
needs buffer memory this profile does not have). The `GLM53_*` variables
that older vLLM manifests carried are not read by this TensorFold image.

Measured on 2026-10-01/02 (server-side for 20k-100k, wall-clock via direct pod
port for 500k; rollout of #3370 loaded in ~415 s on rank 0, 0 restarts):

| Prompt | Before | After | Change |
| ---: | ---: | ---: | ---: |
| 20k | 1,335 tok/s | 1,623 tok/s | +22% |
| 50k | 1,309 tok/s | 1,610 tok/s | +23% |
| 100k | 1,275 tok/s | 1,578 tok/s | +24% |
| 500k | 998 tok/s | 1,171 tok/s | +17% |
| 987k | 797 tok/s (1,238 s) | not re-run; ~1,000 s projected | |

Memory under load after #3370: 20k-100k bottoms at 4.52 GiB (rank 0) / 3.88 GiB
(rank 1) `MemAvailable`; 500k at 3.06 / 3.39 GiB. A single 5 s sample at 1.79 GiB on
rank 1 occurred while the pods were still loading weights, before serving began.
The ~1M floor measured before #3370 was ~2.4 GiB on rank 0 and has not been
re-measured. Prefix caching still works: an identical resend or a multi-turn
follow-up with an exact shared prefix hits the cache, while a different leading
prompt does not.

Startup estimate headroom is small (88.07GiB estimated within 88.21GiB budget
on rank 0 before the change; 91.39 / 90.32GiB on ranks 0 / 1 after). If
TensorFold ever refuses to start with a zero fitting window, revert #3370 first.

## Client route (St. Petersburg GLM)

Codex and other workers reach the GLM model through CLIProxy, not the model
Service directly:

| Item | Value |
| --- | --- |
| Base URL | `http://cliproxy.cliproxy.svc.cluster.local:8317/v1` |
| Model | `vllm/GLM-5.3-Flash-EXL3` |
| `wire_api` | `responses` (Codex custom providers use the Responses API) |
| Context window | 1,048,576 tokens |

Example Codex provider block:

```toml
[model_providers.cliproxy]
name = "CLIProxy"
base_url = "http://cliproxy.cliproxy.svc.cluster.local:8317/v1"
wire_api = "responses"
```

Keep worker `OPENAI_BASE_URL` values unchanged. CLIProxy forwards the model to
`model-serving.ai:8888` through the mesh and egress aliases described above.

Operational notes from the 1M-context qualification:

- Largest proven prompt: 987,104 server tokens (~94% of the window), with a
  passphrase at token 0 retrieved at the end. No pod restarts.
- No timeout was found on the CLIProxy path (a 750k request ran 850 s). The risk
  for ~1M prompts (about 1,000 s of prefill) is a Renovate- or Flux-driven CLIProxy
  rollout mid-request: its Deployment uses `Recreate`, so an in-flight request
  is dropped as "Remote end closed connection without response".
- TensorFold does not implement `POST /tokenize`; use `usage.prompt_tokens` in
  completions and `prompt_tokens_total` on `/health` or `/metrics` for exact counts.
