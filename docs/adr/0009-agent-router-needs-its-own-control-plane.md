# Agent Router needs its own control plane, so it leaves the shared one

Status: accepted, 2026-09-24

## Decision

Envoy AI Gateway (Agent Router) is removed from Ottawa. Do not re-enable it on
the Envoy Gateway control plane that serves `private`, `public` and `ts`.

Its `AIGatewayRoute` model routing only works when the AI controller is
registered as an `extensionManager` xDS translation hook. That hook has no
GatewayClass or Gateway scoping in Envoy Gateway v1.9.1 — `ExtensionManager`
is a field on the singleton `EnvoyGateway` config, so registering it makes the
AI controller a participant in translating *every* gateway the control plane
owns. On Ottawa that is every externally reachable service in the fleet.

Enabling it (#3179) froze all four gateways for 21 hours. `Translate()` began
returning an error on every pass, and the xds runner only writes the snapshot
cache when `err == nil`, so no gateway received any config at all while each
kept serving its last good snapshot. Route status still read `Accepted=True`
throughout, because status is published by a different runner that was not
failing. Nothing alerted.

If Agent Router is wanted later, it gets a second Envoy Gateway control plane
with its own `controllerName` and its own `extensionManager`. Then the hook is
scoped by construction and the shared gateways cannot be affected. Terminating
AI traffic at CLIProxy is the interim state; it is not better, it is only
narrower in blast radius.

## Facts at decision time

Read live from Ottawa on 2026-09-24; source facts from Envoy Gateway `v1.9.1`.

| fact | value |
| --- | --- |
| hook enabled by | #3179, `2026-09-23T23:26:22Z` |
| control plane rolled | `2026-09-23T23:26:38Z`, 16s later |
| `xds-ir` translations | 240 handled, 222 failed; `+4/+4` over a 35 min sample |
| `gateway-api` runner | 86,974 events, **0** failures — hence `Accepted=True` |
| snapshot frozen at | `private` 09-18T17:53Z, `ts` 09-22T23:46Z, `public` 09-23T23:16Z |
| `ExtensionManager` scoping | none; field on the singleton `EnvoyGateway` config |
| `listener.includeAll` default | `false` — #3179 set `true` |
| `route.includeAll` default | `false` — #3179 set `true` |
| `cluster.includeAll` default | `true` — cannot be narrowed to zero |
| `secret.includeAll` default | `true` — cannot be narrowed to zero |
| Ottawa provider recomputes | 88,100 over 21h, against 4 on rb and 18 on sp |
| consumers of `ai-gateway.cliproxy.svc` | none; the canary cutover never ran |

The cache gate is the mechanism, quoting
`internal/xds/runner/runner.go`: "Only update the snapshot cache when there are
no system-level errors, to avoid publishing partial resources."

## What this hid

Every gateway change merged during the freeze silently did nothing:

- #3189's four tailnet `parentRef`s (`plex`, `garage`, `jetkvm`,
  `unifi-webhook`) never reached the `ts` data plane.
- `ai.*` 404ed from creation. The route was created after the freeze began, so
  it was never programmed. Three manifest fixes (#3190, #3199, #3205) were
  written against a cause that was never in the manifests.
- #3213's webtop common hostname could not land.
- `ts` lost its `*.keiretsu.top` filter chain entirely.

## Why not keep it at safe defaults

Returning `listener.includeAll` and `route.includeAll` to `false` would very
likely have been enough — those were the two fields #3179 moved off their
defaults. It was rejected anyway. `cluster.includeAll` and `secret.includeAll`
default to `true` for backward compatibility, so every gateway's clusters and
secrets keep flowing through the AI controller on every translation no matter
how the hook is tuned. The coupling can be reduced but not removed, the
failure it produces is silent, and any future chart bump can re-arm it.

Agent Router was not misconfigured — its `AIGatewayRoute` matched the live
model exactly (`GLM-5.3-Flash-EXL3`, `max_model_len` 262144). It was two lines
from working. It is removed because a component that can silently freeze
unrelated production ingress, with no scoping available, is not worth carrying
for a cutover that has not happened.
