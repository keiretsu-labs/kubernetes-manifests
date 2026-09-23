# In-region model swap (St. Petersburg ↔ CLIProxy)

Workers keep a **stable** model id. St. Petersburg changes the **served**
model underneath. Retarget CLIProxy + `--served-model-name`; do **not**
rename worker-facing models to match whatever SP happens to serve.

## Contract (current)

| Layer | Sticky | Ephemeral (edit on swap) |
|---|---|---|
| K8s LWS / Service / ServiceMonitor / mesh | `ai/qwen38*` identity | image, args, weights, runtime (vLLM vs SGLang) |
| Worker model id via CLIProxy | `vllm/Qwen3.8-Flash-Next` | — |
| CLIProxy `vllm` catalog | keep alias `Qwen3.8-Flash-Next` | add/replace ephemeral alias (today `GLM-5.3-Flash-EXL3`); metadata override facts |
| SP `--served-model-name` | **must include** `Qwen3.8-Flash-Next` | also include the new canonical served id |
| Grafana `dashboards/vllm` | keep `sglang.yaml` + `dashboards.yaml` + `gpu-dcgm.yaml` listed | `$model` / `$workload` / `$container` variables |

**CLIProxy gotcha (#2783):** CLIProxy sends the *alias* upstream. If that
alias is missing from `--served-model-name`, completions 404 and the
cooling breaker can hide the route until restart. Always serve both names.

## Swap checklist (10 steps)

1. Choose ephemeral served id; keep `Qwen3.8-Flash-Next` as the worker alias.
2. Edit `kubernetes/apps/base/ai/ai/inference/qwen38.yaml`: image/recipe/env and
   `--served-model-name <ephemeral> Qwen3.8-Flash-Next` on **leader and worker**.
   Keep resource names `qwen38*`.
3. Update the active-deployment block in
   `kubernetes/apps/base/ai/ai/inference/README.md`.
4. Edit `kubernetes/apps/base/cliproxy/cliproxy/app/providers/providers.yaml`:
   keep the `Qwen3.8-Flash-Next` alias; add/replace the ephemeral alias;
   leave `base-url: http://stpetersburg-vllm-upstream/v1`.
5. Edit `kubernetes/apps/base/cliproxy/cliproxy/app/deployment.yaml`:
   - `payload.override` models must list every `vllm/<alias>` that needs
     developer→system rewrite.
   - `metadata_alias_sources["vllm/Qwen3.8-Flash-Next"]` → `vllm/<ephemeral>`.
   - Put context/max_tokens/reasoning only on the ephemeral
     `metadata_overrides` entry (stable alias inherits).
6. Do **not** remove entries from
   `kubernetes/apps/base/monitoring/grafana/dashboards/vllm/kustomization.yaml`
   during a swap (#2573).
7. In Grafana, pick `$model` from labels; set `$container` to `vllm` or
   `sglang` to match the runtime container (`$workload` stays `qwen38`).
8. Run:
   `tools/check-cliproxy-pi-bridge.sh && tools/check-inference-dashboard-wiring.sh && tools/orphans.sh`
9. Ship via GitOps PR only — no production `kubectl apply`.
10. Accept: LWS Ready; `/v1/models` lists both names; CLIProxy completion with
    `model=vllm/Qwen3.8-Flash-Next` returns 200; Pi/Bhaiya limits match
    overrides; inference Grafana panels populate for `$model`.

## Breakage modes we already hit

| Mode | Symptom | Guard now |
|---|---|---|
| Dashboard orphan | GLM swap removed `sglang.yaml` from kustomization; Qwen restore left the file UNLISTED (#2573) | `tools/check-inference-dashboard-wiring.sh` + `tools/orphans.sh` in `tools/check.sh` |
| Hard-coded panels | OOM panels pinned `pod=~qwen38-.*` + `container="sglang"` while runtime is `vllm` | `$workload` / `$container` variables |
| Alias ≠ served | CLIProxy sends alias upstream → 404 + cooling (#2783) | dual `--served-model-name` + contract check |
| Payload/map skew | developer→system rewrite only on old alias | payload lists every `vllm/` alias |
| Docs drift | Ottawa doc still described live discovery + Qwen NVFP4 | keep `docs/cliproxy-ottawa.md` in the same PR |

## Agent Router (`https://theagentrouter.ai/`, Envoy AI Gateway) — decision

### 1) Does it make stable aliases + in-region swap easier than CLIProxy?

**Yes for pure model virtualization; no as a wholesale CLIProxy replacement.**

Agent Router / Envoy AI Gateway has first-class `modelNameOverride` on
`AIGatewayRoute` backendRefs, provider fallback, Kubernetes InferencePool
routing, and OTel GenAI metrics. That is a cleaner “workers always call
logical name X, upstream served id changes” story than CLIProxy’s
alias-sent-upstream behavior.

It does **not** currently replace for us: Codex/Claude OAuth subscription
pooling (`codex-subscription/vllm-fallback`), the Pi-bridge metadata sync
into Bhaiya/OpenCode, tinyauth + API-key split on Ottawa gateways, or the
existing `ai/` + `ai-kartik/` catalogs.

### 2) Migration cost

| Workstream | Cost | Notes |
|---|---|---|
| GitOps: Envoy Gateway + AI Gateway CRDs | Large | New HelmReleases, ReferenceGrants, certs, policies |
| Auth remap | Large | Re-home keys/SSO; every CLIProxy consumer |
| SP virtualized route only | Medium | The slice Agent Router is good at |
| Grafana / OTel GenAI | Medium | Keep scraping vLLM/SGLang either way |
| MCP aggregation | Skip | Not required for this goal |
| Tetrate hosted | Ops-light, control-heavy | Puts private SP Spark routing outside Flux — poor fit |

### 3) Recommendation

**Improve CLIProxy in place (this change set).** Treat Agent Router as a
future option, not a near-term cutover.

- **Now:** dual-alias contract, dashboard/kustomization guards, this checklist.
- **Later (optional hybrid spike):** self-managed Agent Router *only* in front
  of SP for `vllm/*` virtualization/failover; CLIProxy keeps OAuth + Pi bridge.
  Revisit if we outgrow CLIProxy cooling/alias semantics or need InferencePool.
- **Do not:** Tetrate-hosted Agent Router for in-region Spark, and do not
  full-cutover CLIProxy until a spike proves OAuth+Pi parity.

Raj can accept this PR without approving any Agent Router install.

## File map

```
kubernetes/apps/base/ai/ai/inference/qwen38.yaml
kubernetes/apps/base/ai/ai/inference/README.md
kubernetes/apps/base/cliproxy/cliproxy/app/providers/providers.yaml
kubernetes/apps/base/cliproxy/cliproxy/app/deployment.yaml
docs/cliproxy-ottawa.md
docs/ops/in-region-model-swap.md
kubernetes/apps/base/monitoring/grafana/dashboards/vllm/*
tools/check-cliproxy-pi-bridge.sh
tools/check-inference-dashboard-wiring.sh
```

## Related

- #2573 restore SGLang Grafana dashboard kustomization entry
- #2783 CLIProxy alias-sent-upstream 404
- #3146 Pi bridge GLM route alignment
- ADR 0006 (llm-d stays out of St. Petersburg)
