# AI gateway (Agent Router) — Keiretsu adoption

**Product ask:** manageability of AI endpoints we run (stable client URL,
pluggable backends, easy add/remove, Grafana-friendly observability) — not
“survive GLM↔Qwen swap checklists.”

## Recommendation (one paragraph)

**Adopt self-hosted [Agent Router](https://theagentrouter.ai/)** (formerly Envoy
AI Gateway, OSS `aigateway.envoyproxy.io` CRDs, chart `v1.1.0`) as the **front
door for `vllm/*` and other OpenAI-compatible endpoints we manage**, on top of
the Envoy Gateway we already run on Ottawa/SP. Keep **CLIProxy** for what Agent
Router does not replace today: Codex/Claude **OAuth pooling**, the **Pi-bridge**
metadata sync into Bhaiya/OpenCode, and the existing `ai/` + `ai-kartik`
catalogs. Do **not** use Tetrate-hosted Agent Router for private SP Spark.
Phased cutover: (1) install controller + EG `extensionManager` hook,
(2) register SP via `AIServiceBackend` behind a dedicated `Gateway`,
(3) point selected workers at `http://ai-gateway.cliproxy/v1` while CLIProxy
remains the default `OPENAI_BASE_URL`, (4) migrate more backends / GenAI OTel
into Grafana, (5) only then consider shrinking CLIProxy’s `vllm` provider.

## Why not “improve cliproxy checklist forever”

CLIProxy is a good subscription/OAuth multiplexer. It is a poor general AI
endpoint control plane: alias-sent-upstream (#2783), static provider YAML,
cooling semantics, and no first-class model virtualization / InferencePool.
Agent Router gives `AIGatewayRoute` + `AIServiceBackend`, model name
virtualization, provider failover, and OTel GenAI metrics that feed the same
Grafana stack we just fixed for vLLM.

## Endpoint map (today)

| Client-facing | Where | Backend |
|---|---|---|
| `OPENAI_BASE_URL` → CLIProxy (`cliproxy-api.${CLUSTER_DOMAIN}`) | Ottawa | providers: `ai`, `ai-kartik`, `vllm` |
| `vllm/*` via CLIProxy | Ottawa → ClusterMesh | `stpetersburg-vllm-upstream` → `qwen38-mesh.ai.svc.clusterset.local` |
| Direct SP `qwen38` ServiceMonitor `/metrics` | SP | Grafana AI dashboards (see `docs/ops/grafana-ai-inference.md`) |

## This spike (GitOps)

| Path | Purpose |
|---|---|
| `kubernetes/apps/base/envoy-ai-gateway-system/` | Namespace + HelmReleases (`ai-gateway-crds-helm` + `ai-gateway-helm` **v1.1.0**) |
| `kubernetes/apps/ottawa/envoy-ai-gateway-system/` | Flux Kustomization (depends on `envoy-gateway-system-install`) |
| `.../envoy-gw-common/ai-gateway-extension/values-patch.yaml` | **Required** EG `extensionManager` merge (not auto-applied) |
| `.../envoy-ai-gateway-system/routes/` | Example `Gateway` + `AIGatewayRoute` for SP vLLM (**not** in default kustomization) |

### Enablement checklist

1. Merge this PR → Flux installs `envoy-ai-gateway-system` controller on Ottawa.
2. Manually merge `ai-gateway-extension/values-patch.yaml` into the EG
   HelmRelease values (shared control plane — explicit approve).
3. When ready for traffic: add `./routes` to the base kustomization (or a new
   Flux Kustomization) and smoke:
   `curl -H 'Authorization: …' http://<ai-gateway>/v1/models`
4. Point a canary worker: `OPENAI_BASE_URL=http://ai-gateway.cliproxy.svc/v1`
   with model `vllm/Qwen3.8-Flash-Next` (or the GLM alias).
5. Leave CLIProxy as default until OAuth/Pi parity is decided.

### Registering a new AI endpoint

1. Add a `Backend` (or Service) for the upstream.
2. Add `AIServiceBackend` with `schema.name: OpenAI` (or Anthropic/etc.).
3. Add an `AIGatewayRoute` rule matching `x-ai-eg-model: <client-model-id>`.
4. Optional: `modelNameOverride` on the backendRef when the served id differs
   from the client id (the clean replacement for CLIProxy dual-alias hacks).
5. Commit → Flux; no worker rename.

### Observability

Agent Router emits OTel GenAI metrics (tokens, TTFT, fallback). Scrape/bridge
those into Mimir and add panels beside `vllm-inference`. Until then, keep
scraping SP `vllm:*` directly (already working after the Grafana fix PR).

## Risks (honest)

- EG `extensionManager` is a shared-control-plane change — test on Ottawa first.
- Not a drop-in for CLIProxy OAuth pooling / Pi-bridge.
- `routes/` must not be enabled until the extension hook is live or Envoy will
  ignore `AIGatewayRoute`.
