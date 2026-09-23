# Envoy Gateway ↔ Agent Router extension hook

Agent Router (Envoy AI Gateway) requires Envoy Gateway's `extensionManager`
to forward xDS translation hooks to `ai-gateway-controller`.

Merge the values in `values-patch.yaml` into
`kubernetes/apps/base/envoy-gateway-system/envoy-gw-common/install/helmrelease.yaml`
(or apply as a Flux postRender/kustomize patch) **before** expecting
`AIGatewayRoute` objects to program Envoy.

Existing Keiretsu EG values already enable `enableBackend`,
`enableEnvoyPatchPolicy`, and `enableLua`. This patch adds the
`extensionManager` block only.
