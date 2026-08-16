# CLIProxyAPI on Ottawa

CLIProxyAPI runs as a single, GitOps-managed Deployment in the `cliproxy`
namespace. It proxies OAuth-backed Codex and Claude accounts through OpenAI- and
Anthropic-compatible APIs.

## Architecture and endpoints

- Image: `eceasy/cli-proxy-api:v7.2.109`, pinned by digest in Git.
- The image and command were smoke-tested from the official amd64 OCI rootfs: port 8317 opened, `/management.html` returned 200, `/v1/models` returned 401 without the API key and 200 with it.
- State: `cliproxy-data`, a 2 Gi `ceph-block-replicated` RWO PVC mounted at
  `/data`; OAuth files live in `/data/auth`.
- Configuration: an init container reads `Secret/cliproxy-credentials` and
  writes `/config/config.yaml` into a memory-backed `emptyDir`. The file is not
  stored in a ConfigMap or in plaintext in Git.
- Management UI asset: pinned to CPAMC `v1.19.1`, downloaded by a hardened init
  container and verified against SHA-256
  `c8c8a2cf2b4ca87b38ac885821c94f03601ae3c09eb2eca651bd0f82180e6743`.
  CLIProxyAPI's panel auto-updater is disabled, eliminating unpinned fallback
  downloads.
- `Service/cliproxy` exposes `8317`, `1455`, and `54545` inside the cluster.
  Only `8317` is routed permanently. The callback ports are for interactive
  login or an optional temporary port-forward.
- OpenAI-compatible providers `ai` and `ai-kartik` point at
  `http://ai.keiretsu.ts.net/v1` and
  `http://ai-kartik.keiretsu.ts.net/v1`. Startup init containers discover each
  upstream `/v1/models` catalog and expose the models under the `ai/` and
  `ai-kartik/` prefixes. `Service/ai` and `Service/ai-kartik` register the
  tailnet FQDNs with the shared `common-egress` ProxyGroup. Both provider
  configs override CLIProxy's generic compatibility user agent because the
  upstream gateways reject that agent while accepting the Bhaiya-specific
  identifier.
- OpenAI-compatible provider `vllm` points at the St. Petersburg DeepSeek V4
  vLLM service through `Service/stpetersburg-vllm-upstream`. Startup discovery
  exposes its live catalog under the `vllm/` prefix. The stable
  `vllm/DeepSeek-V4-Flash` client alias maps to the upstream
  `deepseek-v4-flash` model. If the upstream catalog is unavailable, CLIProxy
  omits that dead route rather than blocking startup; clients use the available
  Codex subscription model instead.
- `codex-subscription/vllm-fallback` is the GitOps-owned fallback model. It
  maps to the live `gpt-5.3-codex-spark` Codex subscription model and remains
  available whether or not the DeepSeek vLLM endpoint is healthy.
- `force-model-prefix` is enabled and every route owns its client-visible
  prefix: `codex-subscription/<model>` for the logged-in Codex subscription,
  `anthropic-subscription/<model>` for the logged-in Claude subscription,
  `ai/<model>` for `ai.keiretsu.ts.net`, `ai-kartik/<model>` for
  `ai-kartik.keiretsu.ts.net`, and `vllm/<model>` for the St. Petersburg vLLM
  service. The two OAuth prefixes live
  in native per-credential metadata, so CLIProxyAPI itself owns listing,
  request routing, and subscription pooling.
- The pinned OCI digest is `sha256:f8c2f64a…b586311b`; Ottawa currently
  schedules the amd64 image on `asuka`.

| Purpose | URL | Exposure | Authentication |
|---|---|---|---|
| Browser UI / management | `https://cliproxy.keiretsu.top/management.html` | public and private gateways | tinyauth (Raj or Kartik), then the CLIProxy management key |
| Browser UI / management (tailnet) | `http://cliproxy/management.html` (FQDN: `http://cliproxy.keiretsu.ts.net/management.html`) | direct Tailscale LoadBalancer on port 80 | tailnet ACL, then the CLIProxy management key |
| Model API | `https://cliproxy-api.killinit.cc` | **private and ts gateways only** | CLIProxy API key |

The split is enforced by path as well as hostname. Public/private UI routes only
forward `/management.html`, `/v0/management*`, and `/v0/resource/plugins*`.
Model paths (`/v1*`, `/v1beta*`, `/openai/v1*`, and `/backend-api/codex*`) only
exist on `cliproxy-api.killinit.cc`, which has no public gateway and no public
`${COMMON_DOMAIN}` CNAME. Ottawa's `${CLUSTER_DOMAIN}` HTTPRoute DNS integration
makes it resolvable on the intended private/tailnet path.

The UI route has a route-scoped Envoy Lua response filter. Tinyauth represents
an unauthenticated browser as `401` plus `x-tinyauth-location`; the filter
converts only that response into a `302` to the Tinyauth login URL. After the
Tinyauth browser session is established, CPAMC still asks for the independent
CLIProxy management key.

The short `http://cliproxy` tailnet URL is provided by `Service/cliproxy-ts`, a
Tailscale `LoadBalancer` using the shared `common-ingress` ProxyGroup. It goes
directly to application port 8317 and therefore does not traverse Envoy or
tinyauth. Tailnet ACLs control network reachability, while CLIProxy's separate
management key still protects management operations.

`remote-management.allow-remote` is enabled because Envoy is remote from the
pod, but the management API still requires its separate management key. WebSocket
authentication is enabled. Debugging, pprof, file logging, TLS in the pod, and
usage statistics are disabled; TLS terminates at Envoy.

## Status and safe key access

Use the repository wrapper for cluster reads:

```bash
tools/kc.sh ot -n cliproxy get deploy,pod,svc,pvc,httproute,securitypolicy
tools/kc.sh ot -n cliproxy describe httproute cliproxy-ui
tools/kc.sh ot -n cliproxy describe httproute cliproxy-api
```

Avoid printing credentials in terminal output or shell history. Read a key into
a hidden shell variable directly from the Secret:

```bash
read -rs CLIPROXY_API_KEY < <(
  tools/kc.sh ot -n cliproxy get secret cliproxy-credentials \
    -o jsonpath='{.data.api-key}' | base64 -d
)
export CLIPROXY_API_KEY
```

For a management request, use the same pattern with
`{.data.management-key}` and `CLIPROXY_MANAGEMENT_KEY`. Clear values when done:

```bash
unset CLIPROXY_API_KEY CLIPROXY_MANAGEMENT_KEY
```

Do not use `kubectl get secret -o yaml`, paste keys into documentation, or add
OAuth token files to Git.

## OAuth login

The login subcommands write credentials to `/data/auth` on the PVC. They start a
separate CLIProxyAPI process in command mode; they do not modify the running
server configuration. After adding an OAuth credential, set its native
`prefix` field through the management UI or
`PATCH /v0/management/auth-files/fields`: use `codex-subscription` for every
Codex credential and `anthropic-subscription` for every Claude credential.
Credentials that share a prefix form one route pool; the configured
round-robin strategy spreads new sessions across that pool while session
affinity keeps a conversation on its selected credential when it remains
available.

### Codex device flow (preferred)

```bash
tools/kc.sh ot -n cliproxy exec -it deploy/cliproxy -- \
  /CLIProxyAPI/CLIProxyAPI \
  --config /config/config.yaml \
  --codex-device-login \
  --no-browser
```

Open the displayed device URL, enter its one-time code, and wait for the command
to report successful authentication.

### Claude manual callback paste

```bash
tools/kc.sh ot -n cliproxy exec -it deploy/cliproxy -- \
  /CLIProxyAPI/CLIProxyAPI \
  --config /config/config.yaml \
  --claude-login \
  --no-browser
```

Open the displayed authorization URL. After authorization, the browser redirects
to a localhost URL on port `54545`. Copy the **entire callback URL**, including
its query string, from the address bar and paste it into the waiting command.
Do not publish port `54545` through an HTTPRoute.

### Optional temporary local port-forward

A port-forward is useful for localhost callback behavior or viewing the panel
without ingress. Keep it temporary:

```bash
tools/kc.sh ot -n cliproxy port-forward svc/cliproxy \
  8317:8317 1455:1455 54545:54545
```

Then open `http://localhost:8317/management.html`. The management key remains
required.

## Verification requests

These examples obtain the key without displaying it. They are expected to fail
with an authentication error if the key is omitted, and may return an empty
model set until at least one provider login exists.

```bash
read -rs CLIPROXY_API_KEY < <(
  tools/kc.sh ot -n cliproxy get secret cliproxy-credentials \
    -o jsonpath='{.data.api-key}' | base64 -d
)

# OpenAI-compatible model list
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${CLIPROXY_API_KEY}" \
  https://cliproxy-api.killinit.cc/v1/models | jq .

# Anthropic-compatible request template; replace the model after checking /v1/models.
curl --fail-with-body --silent --show-error \
  -H "x-api-key: ${CLIPROXY_API_KEY}" \
  -H 'anthropic-version: 2023-06-01' \
  -H 'content-type: application/json' \
  https://cliproxy-api.killinit.cc/v1/messages \
  --data '{"model":"<CLAUDE_MODEL>","max_tokens":16,"messages":[{"role":"user","content":"Reply OK"}]}' \
  | jq .

# OpenAI Responses request template; replace the model after checking /v1/models.
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer ${CLIPROXY_API_KEY}" \
  -H 'content-type: application/json' \
  https://cliproxy-api.killinit.cc/v1/responses \
  --data '{"model":"<CODEX_MODEL>","input":"Reply OK"}' \
  | jq .

unset CLIPROXY_API_KEY
```

Management API requests accept either `Authorization: Bearer` or
`X-Management-Key`. Prefer the latter to make the credential's purpose explicit:

```bash
read -rs CLIPROXY_MANAGEMENT_KEY < <(
  tools/kc.sh ot -n cliproxy get secret cliproxy-credentials \
    -o jsonpath='{.data.management-key}' | base64 -d
)
curl --fail-with-body --silent --show-error \
  -H "X-Management-Key: ${CLIPROXY_MANAGEMENT_KEY}" \
  https://cliproxy.keiretsu.top/v0/management/config | jq .
unset CLIPROXY_MANAGEMENT_KEY
```

Both UI routes also require an authenticated tinyauth browser session.

## Configuration and key rotation

The generated configuration is **GitOps-owned**. Do not treat configuration
edits made in the management panel as authoritative: the next pod recreation
regenerates `/config/config.yaml` from the Deployment template and Secret.
Change configuration in this repository and let Flux reconcile it.

To rotate either key, edit the existing SOPS file from the directory whose
`.sops.yaml` rules apply:

```bash
sops kubernetes/apps/base/cliproxy/cliproxy/app/secret.sops.yaml
```

Change `stringData.api-key` and/or `stringData.management-key`, save, verify the
file remains encrypted, then update a pod-template annotation such as
`cliproxy.keiretsu.top/credentials-revision` in `deployment.yaml` in the same
commit. That GitOps-owned template change rolls the pod so the init container
regenerates the config. Verify the rollout and both authenticated endpoints.

## Upgrade and rollback

1. Verify the upstream release and multi-architecture digest.
2. Update **both** image references in `deployment.yaml` (init container and
   server) to the same immutable tag and digest.
3. Run `tools/check.sh talos-ottawa` and review the rendered Deployment.
4. Commit through the normal GitOps process and let Flux reconcile.
5. Verify Deployment readiness, both HTTPRoutes, SecurityPolicy, `/v1/models`,
   and one real request through each configured provider.

The Deployment uses one replica and `Recreate`, preventing RWO Ceph multi-attach
during upgrades. A brief outage is expected.

To roll back, revert the image change in Git (or revert the responsible commit),
run the Ottawa check again, and let Flux reconcile. OAuth credentials remain on
the PVC and are not tied to the container image. If a new version changes token
formats, take or confirm a successful Velero backup before upgrade and consult
upstream release notes before restoring older software.

## PVC and Velero

`Schedule/cliproxy-backup` runs daily at `09:00` UTC, retains backups for seven
days (`168h`), includes the `cliproxy` namespace, and enables filesystem volume
backup. It protects `/data/auth` and the management panel cache on the PVC.

Check schedules and recent backups without mutating the cluster:

```bash
tools/kc.sh ot -n velero-system get schedule cliproxy-backup
tools/kc.sh ot -n velero-system get backup \
  -l velero.io/schedule-name=cliproxy-backup
```

Before a risky upgrade, verify the latest backup is `Completed`. Restore work is
an operator-controlled Velero procedure: avoid restoring into the live namespace
while the Deployment is writing the PVC, and preserve the encrypted Git Secret
separately because it is the source for API and management keys.
