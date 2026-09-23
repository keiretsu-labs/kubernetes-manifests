# Envoy Gateway ↔ Agent Router extension hook

Agent Router (Envoy AI Gateway) requires Envoy Gateway's `extensionManager`
to forward xDS translation hooks to `ai-gateway-controller`.

**Status:** the `extensionManager` block from `values-patch.yaml` is merged
into `../install/helmrelease.yaml` (GitOps). Pod annotation
`config.keiretsu.top/extension-apis` is bumped so the controller rolls.

`values-patch.yaml` remains the readable source-of-truth snippet for the
hook shape (upstream Agent Router envoy-gateway-values.yaml).

## Still gated

- `kubernetes/apps/base/envoy-ai-gateway-system/routes/` is **not** in the
  default kustomization until a canary is approved.
- Workers keep CLIProxy as `OPENAI_BASE_URL` until canary.
- Canary model id: **`vllm/default`** (or `vllm/auto`); see `docs/ops/ai-gateway.md`.
