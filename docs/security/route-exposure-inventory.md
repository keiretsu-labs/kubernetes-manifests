# Route exposure inventory (hostname → backend → auth layer)

Every externally-reachable route, derived from the git tree (branch base:
`main` @ `59a16e200`, 2026-10-16). Documentation only — no route, policy, or
DNS change is proposed here.

Auth-layer legend:

- **tinyauth** — route carries an Envoy `SecurityPolicy` with `extAuth` → the
  `tinyauth`/`tinyauth-killinit` Service plus a `Remote-Email` allow-list
  (see `kubernetes/apps/base/auth/README.md`).
- **app** — the application runs its own login/OIDC; no gateway auth.
- **none** — no auth layer found on the route.
- **tailnet** — reachable only on the tailnet; Tailscale policy is the gate.

Exposure tiers: `public` = Gateway `public` (Internet via Cloudflare DNS),
`private` = Gateway `private` (LAN only, never published to Cloudflare),
`ts` = Gateway `ts` (tailnet only). `cdn` = k8gb GSLB fronting one of the
above; the underlying HTTPRoute is listed.

## Internet-facing (`public` gateway and CDN-fronted)

| Hostname | Route (ns) | Backend | Auth |
|---|---|---|---|
| `home.${CLUSTER_DOMAIN}` / `home.keiretsu.top` | dashboard-public (home); homepage (home) | homer / homepage UI | tinyauth (`homepage-tinyauth`) |
| `cliproxy.${COMMON_DOMAIN}` | cliproxy-ui (home) | cliproxy UI | tinyauth (`cliproxy-ui-tinyauth`) |
| `cliproxy-api.${CLUSTER_DOMAIN}` | cliproxy-api (home) | cliproxy API | api token (app) |
| `firefly.${COMMON_DOMAIN}` | firefly (firefly) | firefly UI | tinyauth (`firefly` SP) |
| `frigate.${COMMON_DOMAIN}` / `*.${LOCATION}` | frigate (home) ottawa | frigate UI | tinyauth (`frigate-tinyauth`) |
| `frigate.${CLUSTER_DOMAIN}` | frigate (home) robbinsdale | frigate UI | none found on route (see note) |
| `homeassistant.${CLUSTER_DOMAIN}` | homeassistant (home-assistant) | HA UI | app login (+ long-lived tokens) |
| `status.${CLUSTER_DOMAIN}` | gatus (monitoring, ×3 sites) | gatus status page | none (public status page) |
| `kromgo.${CLUSTER_DOMAIN}` | kromgo (monitoring) | kromgo badges | none — intentional, badges only |
| `teslamate.keiretsu.top` | teslamate (teslamate) | teslamate UI | tinyauth (`teslamate-tinyauth`) |
| `tsflow.killinit.cc` / `.lukehouge.com` / `.rajsingh.info` | tsflow (tailscale-examples) | tsflow MCS svc | tailnet identity upstream |
| `audiobookshelf.${CLUSTER_DOMAIN}` | audiobookshelf (media ott) | ABS UI/API | app OIDC (native clients; TINYAUTH_OAUTH_WHITELIST gates signup) |
| `komga.${CLUSTER_DOMAIN}` | komga (media ott) | komga UI | app login |
| `overseerr.${CLUSTER_DOMAIN}` | overseerr (media ott+rb) | overseerr/jellyseerr | app login |
| `tautulli.${CLUSTER_DOMAIN}` | tautulli (media ott) | tautulli | app login |
| `wizarr.${CLUSTER_DOMAIN}` | wizarr (media ott) | wizarr | app login |
| `bookorbit.${CLUSTER_DOMAIN}` | bookorbit (media ott) | bookorbit | app login |
| CDN-fronted: `hubble/prometheus/opencost/victoria-logs/forgejo/gatus/s3` `.cdn.keiretsu.top` | Gslb routes (see `k8gb-common/config`) | regional backends via MCS | tinyauth SPs on the underlying routes (`*-tinyauth`) |
| `www.${COMMON_DOMAIN}` / `s3.${COMMON_DOMAIN}` | garage-web / garage-s3 (garage) | Garage S3 + web | S3 sigv4; web = app |
| `ssh-bhaiya.keiretsu.top` | cloudflared-bhaiya-ssh (Ottawa connector) → `bhaiya-ssh.bhaiya.svc:22` | TCP via CF tunnel | SSH keys + corp/bhaiya authz |

## Site-private (`private` gateway, LAN only)

Media family (ottawa + robbinsdale where noted): `plex`, `radarr-*` (1080p/4k/4kremux/anime), `sonarr-*`, `bazarr-*`, `lidarr`, `prowlarr`, `sabnzbd`, `autobrr`, `qb`, `qb-pvt`, `maintainerr`, `shelfmark`, `suwayomi` (tinyauth via `suwayomi-tinyauth` on killinit cookie), `omnibus`, `tracearr` — all **app login** except suwayomi; none published to Cloudflare.

Infra: `grafana.${CLUSTER_DOMAIN}` (ts+private, tinyauth), `prometheus.${CLUSTER_DOMAIN}` (ts, tinyauth/OIDC), `headlamp.${CLUSTER_DOMAIN}` (ts), `hubble.${CLUSTER_DOMAIN}` (ts), `rook.${CLUSTER_DOMAIN}` (ott ts, rb private), `searxng.${CLUSTER_DOMAIN}` (ts), `opencost.${CLUSTER_DOMAIN}` (ott), `webtop.${CLUSTER_DOMAIN}` (ts), `k9s.${CLUSTER_DOMAIN}` (ts), `jetkvm.${CLUSTER_DOMAIN}` (private), `unifi-webhook.${CLUSTER_DOMAIN}` (private), `speedtest.${CLUSTER_DOMAIN}` (rb private), `homeassistant.${CLUSTER_DOMAIN}` (ott/rb private), `frigate` (rb), `garage-webui.${CLUSTER_DOMAIN}` (tinyauth-killinit), `auth.${COMMON_DOMAIN}` + killinit variant (tinyauth login itself), `forgejo.${CLUSTER_DOMAIN}` (private + ts; app OAuth/SSH), `woodpecker.${CLUSTER_DOMAIN}` (private; tinyauth on UI), `litellm` (private, bearer master key).

## Cloudflare tunnels (non-gateway ingress path)

| Tunnel | Connector | Ingress (remote-managed in CF) | Auth |
|---|---|---|---|
| bhaiya-ssh `61ba829d-…` | `cloudflared-bhaiya-ssh` ×2 (Ottawa) | `ssh-bhaiya.keiretsu.top` → tcp://`bhaiya-ssh.bhaiya.svc.cluster.local:22` | SSH keys + bhaiya authz; details `docs/reference/ssh-cloudflare-tunnel.md` |
| lukehouge `cloudflared-luke` ×2 (Robbinsdale) | token `cloudflared-k8s-tunnel-token-lukehouge-com` | ingress lives in CF dashboard (not in git) — Robbinsdale bypass of its public Envoy tier; verify hostnames in CF before relying on this path | n/a (remote config) |

St. Petersburg `cloudflare-stpetersburg` deploys DNS/external-dns only; its
`openwebui` HelmRelease is fully commented out (no live route).

## Notes

- The strimzi TLSRoutes reference a non-existent Gateway/section; documented
  in `docs/reference/architecture.md` (dangling, inert).
- `auth` ReferenceGrants differ per cluster (ottawa wider than rb/sp); see
  architecture.md §Authorization for the trap table.
- Re-derive with:
  `git grep -l "kind: HTTPRoute" -- kubernetes/apps/base | grep -v k8gb` plus
  `git grep -l "kind: SecurityPolicy"`.
