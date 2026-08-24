# Firefly III MCP integration contract

## Upstream pin

- Repository: <https://github.com/daften/fireflyiii-mcp>
- Release: `v0.4.2`
- Source commit: `e7894fa46243dff3a43a0651105a294faeedb7da`
- Image: `ghcr.io/daften/fireflyiii-mcp:0.4.2`
- Image index digest: `sha256:2e756227c8b4298196c33a1090a96b4952405e9dbe83cd4255efb1407c103f1e`
- License: MIT

The upstream image serves Streamable HTTP MCP on port `3000`; `GET /health`
returns `{"status":"ok"}`. Requests without a bearer token return HTTP 401.
The deployment starts the upstream server with `--read-only`, so mutation tools
are not registered.

## Secret and environment contract

External Secrets materializes `firefly/firefly-mcp` from the local
ClusterSecretStore key `firefly-iii`, properties:

- `FIREFLY_III_URL`: Firefly III origin, without an `/api/v1` suffix.
- `FIREFLY_III_TOKEN`: Firefly III Personal Access Token.

The Deployment maps these to the upstream-required variables:

- `FIREFLY_URL` <- `FIREFLY_III_URL`
- `FIREFLY_TOKEN` <- `FIREFLY_III_TOKEN`

No plaintext or SOPS token value is added by this change.

## Network and client contract

- Service: `firefly-mcp.firefly.svc.cluster.local:3000`
- Only Bhaiya may access the MCP listener; host/remote-node access is limited to
  `GET /health` for probes.
- Bhaiya sends `Authorization: Bearer <Firefly III PAT>` to the Streamable HTTP
  endpoint. The upstream resolves the bearer token per request and uses it for
  Firefly III API calls.
- No public HTTPRoute is created; Bhaiya remains the user-facing auth/UI boundary.

## Verification

The upstream checkout at the source commit passed `npm run check`: Biome,
TypeScript, and 438 passing tests. Thirteen live integration tests were skipped
because no Firefly III credentials were available in the build workspace.
A real local upstream HTTP smoke test also verified `/health`, 401 without a
bearer token, and MCP `initialize` returning server `firefly-iii-mcp` version
`0.4.2` over SSE.

The Kubernetes manifest files pass YAML parsing and `git diff --check`.
The repository's canonical `./tools/check.sh ot` could not complete in this
workspace because its Flate bootstrap requires `tar`, which is absent; this is
a host-tooling blocker, not a manifest diagnostic.

The ExternalSecret prerequisite is an existing backend record named `firefly-iii`
with the two properties above. It must be provisioned separately by the cluster
secret operator.

## Existing Firefly III app

The repository already deploys Firefly III itself in the Ottawa `firefly`
namespace. This MCP service is intentionally colocated in the `firefly`
namespace, but remains a separate Flux child and NetworkPolicy boundary.
