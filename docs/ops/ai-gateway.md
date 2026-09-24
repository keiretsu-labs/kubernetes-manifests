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
| `vllm/*` via CLIProxy | Ottawa → ClusterMesh | `stpetersburg-vllm-upstream` → `model-serving-mesh.ai.svc.clusterset.local` |
| Direct SP `model-serving` ServiceMonitor `/metrics` | SP | Grafana AI dashboards (see `docs/ops/grafana-ai-inference.md`) |


## Model ids name the model that answers

| Setting | Value |
|---|---|
| `OPENAI_BASE_URL` | `http://ai-gateway.cliproxy.svc.cluster.local/v1` (Gateway in `cliproxy`) or CLIProxy until cutover |
| `model` | the served name, namespaced: **`vllm/GLM-5.3-Flash-EXL3`** |

**Reversal (2026-09-23): the `vllm/default` / `vllm/auto` aliases are gone.**
They bought a one-line model swap and charged the metadata tier for it.
models.dev, LiteLLM's registry and every harness's built-in table are keyed by
model id, so `vllm/default` resolves to nothing and the client silently falls
back to a generic context window. That is the same failure this stack already
hit from the other direction, when the Pi bridge published a 1M window against
a server running `--max-model-len 16384`.

`vllm/` remains a route namespace, not an alias: it selects the backend and
`modelNameOverride` strips it back to the served name. A swap now edits the
route and regenerates worker config from the serving profile, which is the
point — the profile is the only thing that knows the real limits, so it should
be the thing that propagates.

Retired ids are not kept as compatibility shims. `vllm/Qwen3.8-Flash-Next`
used to rewrite onto GLM, which is the routing-layer version of lying about a
model: the client believes it reached Qwen and keeps Qwen's assumptions.

## This spike (GitOps)

| Path | Purpose |
|---|---|
| `kubernetes/apps/base/envoy-ai-gateway-system/` | Namespace + HelmReleases (`ai-gateway-crds-helm` + `ai-gateway-helm` **v1.1.0**) |
| `kubernetes/apps/ottawa/envoy-ai-gateway-system/` | Flux Kustomization (depends on `envoy-gateway-system-install`) |
| `.../envoy-gw-common/ai-gateway-extension/values-patch.yaml` | EG `extensionManager` snippet (merged into EG HelmRelease via #3179) |
| `.../envoy-ai-gateway-system/routes/` | `Gateway` + `AIGatewayRoute` for SP vLLM (Flux KS `envoy-ai-gateway-system-routes` → `cliproxy`) |

### Enablement checklist

1. Merge this PR → Flux installs `envoy-ai-gateway-system` controller on Ottawa.
2. ~~Merge `ai-gateway-extension/values-patch.yaml` into the EG HelmRelease~~
   — landed via the `feat/eg-ai-gateway-extension-manager` follow-up (shared CP).
3. Routes via Flux KS `envoy-ai-gateway-system-routes` (`targetNamespace: cliproxy`).
   Smoke: `curl http://ai-gateway.cliproxy.svc.cluster.local/v1/models` + completion `vllm/default`.
   Stable alias: Service `ai-gateway` (ExternalName) in `cliproxy` → EG data-plane Service.
4. Point a canary worker: `OPENAI_BASE_URL=http://ai-gateway.cliproxy.svc/v1`
   with model **`vllm/default`** (or alias `vllm/auto`). Do not put GLM/Qwen served names in worker config.
5. Leave CLIProxy as default until OAuth/Pi parity is decided.

### Registering a new AI endpoint

1. Add a `Backend` (or Service) for the upstream.
2. Add `AIServiceBackend` with `schema.name: OpenAI` (or Anthropic/etc.).
3. Add an `AIGatewayRoute` rule matching `x-ai-eg-model: <client-model-id>`.
4. Set `modelNameOverride` on the backendRef to the **active served name**.
   Expose the served name to clients too — do not invent a stable alias for it.
   An id no catalog can resolve costs you the model's limits.
5. Commit → Flux; no worker rename.

### Observability

Agent Router emits OTel GenAI metrics (tokens, TTFT, fallback). Scrape/bridge
those into Mimir and add panels beside `vllm-inference`. Until then, keep
scraping SP `vllm:*` directly (already working after the Grafana fix PR).

## Risks (honest)

- EG `extensionManager` is a shared-control-plane change — test on Ottawa first.
- Not a drop-in for CLIProxy OAuth pooling / Pi-bridge.
- `routes/` requires the EG `extensionManager` hook; without it Envoy ignores
  `AIGatewayRoute` (hook enabled via #3179).
- **The client-facing wire format is fixed to OpenAI.** `AIServiceBackend`
  accepts `Anthropic` / `AWSAnthropic` / `GCPAnthropic` as *backend* schemas,
  but `AIGatewayRoute` (v1beta1) has no input-schema field, so the gateway only
  parses OpenAI-shaped requests. Claude Code talks the Anthropic Messages API
  and therefore cannot be model-virtualized here — if CLIProxy moves behind
  this Gateway, its Anthropic, Gemini (`/v1beta`) and Codex
  (`/backend-api/codex`) paths must be carried by a plain `HTTPRoute` on the
  same Gateway as passthrough, not by an `AIGatewayRoute`.
