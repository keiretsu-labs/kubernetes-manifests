# Bhaiya SSH outbound tunnel

> Classification: runbook. Root cause and evidence: issue #661 and
> `docs/agent-knowledge/ssh-public-path-investigation-20260909.md` (PR #3428).

The UniFi gateway injects forged TCP RSTs into long-lived connections to the
public VIP, so SSH over public `:22` or `:6922` drops after seconds to minutes.
This path avoids UniFi entirely. `cloudflared-bhaiya-ssh` in Ottawa dials **out**
to Cloudflare, and Cloudflare forwards `ssh-bhaiya.keiretsu.top` back down that
connection to `bhaiya-ssh.bhaiya.svc.cluster.local:22` (the SSH mux). It does not
use the Envoy Gateway listeners, so listener reloads cannot cut these sessions.

## Components

| Piece | Where |
|---|---|
| Connector Deployment (2 replicas, token mode) | `kubernetes/apps/base/cloudflare/cloudflared-bhaiya-ssh/` |
| Flux pointer (Ottawa) | `kubernetes/apps/ottawa/cloudflare/cloudflared-bhaiya-ssh.yaml` |
| Tunnel | Raj's existing remotely managed tunnel `61ba829d-3792-482d-98e3-29daf1536f5d`, account `Rajsinghcpre@gmail.com's Account` (`bf7f2d10…`). Unused since the 2025 "remove all Cloudflare tunnels" change; now dedicated to Bhaiya SSH. |
| Credential | Existing `RAJSINGH_INFO_CLOUDFLARED_TOKEN` in `common-secrets`, substituted by Flux. No new secret. |
| Ingress + DNS | Managed in Cloudflare (remote config): public hostname `ssh-bhaiya.keiretsu.top` -> `TCP` `bhaiya-ssh.bhaiya.svc.cluster.local:22`, proxied CNAME to `61ba829d-….cfargotunnel.com`. |
| Mux allow rule | corp/bhaiya `deploy/ssh-networkpolicy.yaml` allows `cloudflare/bhaiya-ssh-tunnel` pods to port 2223. |

Do not run any other connector with this tunnel's token. Connectors of one
tunnel are load-balanced replicas.

## Why `ssh-bhaiya.keiretsu.top` and not `ssh.bhaiya.keiretsu.top`

keiretsu.top is on the Cloudflare Free plan. Universal SSL covers only the apex
and `*.keiretsu.top`. `cloudflared access` connects to the hostname over TLS at
the Cloudflare edge, so a two-level name would fail the handshake without a paid
Advanced Certificate. `ssh-bhaiya` is one level and covered.

## Why the ingress is not in Git

The tunnel is remotely managed. A test on 2026-10-05 showed that Cloudflare
pushes its remote config (version 5) over any local `ingress:` block, so a
locally managed config cannot override it. None of the existing API tokens has
`Account > Cloudflare Tunnel > Edit` (`RAJSINGH_INFO_CLOUDFLARE_API_TOKEN` has
DNS edit on keiretsu.top only). The public hostname is therefore added once in
the dashboard. If a token with Tunnel Edit is added later, move it to
`PUT /accounts/{acct}/cfd_tunnel/61ba829d…/configurations`.

## One-time dashboard step (Raj)

Cloudflare dashboard -> Zero Trust -> Networks -> Tunnels -> tunnel
`61ba829d…` -> Public Hostname -> Add:

- Subdomain `ssh-bhaiya`, Domain `keiretsu.top`, Path empty
- Service Type `TCP`, URL `bhaiya-ssh.bhaiya.svc.cluster.local:22`

The dashboard creates the proxied CNAME. Do not add a Cloudflare Access
application in front of it unless clients are also given Access login steps.
SSH key authorization stays at the Bhaiya mux.

## Verify

1. `kubectl -n cloudflare get deploy cloudflared-bhaiya-ssh`: 2/2 Ready, and
   logs show `Registered tunnel connection` and an ingress containing
   `ssh-bhaiya.keiretsu.top`.
2. `dig +short ssh-bhaiya.keiretsu.top` returns Cloudflare anycast addresses.
3. From outside the tailnet, open a workspace SSH session through the tunnel
   and keep it active (typing or output) for more than 10 minutes. Record the
   start and end in the lane status.

## Clients

See corp/bhaiya `docs/ssh-workspace-gateway.md` ("Outbound Cloudflare path").
Short form: install `cloudflared`, then either
`BHAIYA_SSH_TUNNEL_HOST=ssh-bhaiya.keiretsu.top bhaiyactl bots ssh NAME`, or an
`~/.ssh/config` ProxyCommand that speaks the mux CONNECT preface over
`cloudflared access ssh --hostname ssh-bhaiya.keiretsu.top`.

## Rollback

Delete the public hostname in the dashboard, or suspend/remove the Flux pointer.
The public `:22`/`:6922` and tailnet paths are unchanged.
