# Tracearr: stream-aware upgrade gate, account-sharing signals, media bots (proposal, docs-only)

## 1. Tracearr today
- Deployed in kman for both sites: `kubernetes/apps/base/media/media-ottawa/tracearr/` and `media-robbinsdale/tracearr/` (app, postgres, dragonfly, httproute, s3-backup), next to `plex/` in the same media namespace for each site.
- Upstream: github.com/connorgallopo/tracearr. Supports Plex/Jellyfin/Emby. Interactive reference lives at `/api-docs` on the instance.

### Public API (from upstream source)
- Auth: `Authorization: Bearer trr_pub_<key>`. Key is created under Settings. Read-only scope fits a gate.
- v1 (`/api/v1`): `/health`, `/stats`, `/stats/today`, `/streams` (`?serverId=`, `?summary=true`), `/users`, `/violations`, `/history`, `/activity`.
- v2 (`/api/v2`): `/streams`, `/users`, `/users/:id`, `/users/:id/stats`, `/users/:id/history`, `/violations`, `/violations/:id`, `/servers`, `/libraries`, `/media`, `/history`, plus **`/events` SSE** with these types: `stream.started|updated|progress|stopped`, `violation.created`, `server.health`. Events are not replayed, so clients refetch over REST when they reconnect.
- `/streams` reads from the in-memory active-session cache. Each stream has a server, user, media, state, progress, transcode/direct decision, bitrate, device/player/platform, and startedAt. The summary gives total, transcodes, directPlays, totalBitrate, and byServer.
- Rate limit: the per-minute limit is set in the admin setting `publicApiRateLimitPerMinute`. Polling every 30s is fine.
- Notifications: Discord, ntfy, Gotify, Apprise, Pushover, JSON webhook, email, mobile push.
- Stability: the API is versioned (v1 and v2), and upstream has security and rate-limit tests. Build against v2, and pin the image through Renovate as usual.

## 2. Account-sharing signals
- Built-in rule types: `concurrent_streams` (per-user limit), `simultaneous_locations`, `impossible_travel`, `device_velocity` (too many distinct IPs in a window), `geo_restriction`, `account_inactivity`. Tracearr also has trust scores and merged users across servers.
- Data: `/violations` (v2, with detail by id), the `violation.created` SSE event, `/users/:id/history` (IP and geo data, including ASN, for each session), and per-user trust scores.
- Automations can also `kill_stream` or `message_client`. **Policy: notify only. Do not enable kill or ban actions.** Raj or Kartik decides by hand.
- Report: a weekly digest per user (max concurrent streams, distinct IPs/cities/devices over 7 days, any open violations, trust score), posted to the same channel as the bot. Each violation gets one notification with an "acknowledge" link back to Tracearr.

## 3. Stream gate design (recommended: small gate service)
`stream-gate` Deployment in each site's media namespace, read-only Tracearr key from a secret (SOPS for now):
- Subscribes to `/api/v2/events` and runs a REST reconcile every 60s.
- `GET /ready?node=<n>&scope=media|node|ceph`. It returns 200 when no **counted** stream is affected:
  - `node`: streams whose Plex/Jellyfin pod runs on that node. It maps pod to node through the k8s API, using a view-only SA.
  - `ceph` / `media`: any counted stream at the site.
- **Shared accounts:** count *sessions* rather than users, so one shared login with 3 streams counts as 3. Paused streams idle for more than 20 minutes, and sessions from accounts flagged by an open `concurrent_streams` or `device_velocity` violation, don't hold the gate for longer than 1h. That way abusers can't block maintenance indefinitely.
- Max wait: after `MAX_WAIT` (default 6h, or the configured maintenance window) the gate returns 200 with `reason=timeout`, so **tuppr never stalls forever**. Override: an annotation `stream-gate/override=until:<ts>` applied through a GitOps commit.
- Fail-open: if Tracearr is down for 10 minutes, the gate returns 200 and sends a notification.

Consumers:
- **tuppr** (Talos/k8s): add the gate as a tuppr health check before each node, e.g. an HTTP/CEL check against `/ready?node=`. If tuppr doesn't support HTTP checks, the gate writes a ConfigMap or Lease `stream-gate-<site>` with `ready: true|false` and tuppr checks that object. tuppr stays the only upgrade path.
- **Flux/Renovate apps:** media HelmReleases keep Renovate PRs; the merge bot checks `/ready?scope=media` before merging. This generalizes the #3492 box watcher ("merge on Plex idle") into a cluster service, and the box watcher can be retired afterward. No Flux suspend/resume controller is needed.
- **Ceph maintenance (noout, OSD work):** the runbook step calls `/ready?scope=ceph`.
- **Plex restarts:** the same media scope applies.
- Rejected options: a Flux suspend-window controller (it mutates Flux state outside Git), and gating Renovate's schedule alone (too coarse).

## 4. Bots (recommended: one simple setup)
- **Requests:** Seerr (the merged Overseerr/Jellyseerr successor) per site, plus **Doplarr** on Discord (simple, slash commands). Requestrr is a fallback. Tracearr already links to Seerr, so it shows who requested a title and whether they watched it.
- **What's-playing / tracking:** don't run a separate bot. Point Tracearr's built-in Discord notifications at a `#media` channel for stream start/stop (optional) and violations. Add a small `/playing` slash command inside the same Discord app (or a stream-gate sidecar) that calls `/api/v2/streams?summary=true`, plus the weekly sharing digest from section 2.
- Result: one Discord channel, two components (Doplarr and Tracearr notifications), and one tiny gate service that also serves `/playing`.

## 5. Rollout
1. A read-only Tracearr API key per site in a secret. 2. stream-gate in shadow mode (log only) for 1 week. 3. Wire it into the merge bot, then tuppr. 4. Seerr + Doplarr. 5. Notify-only sharing digest.
