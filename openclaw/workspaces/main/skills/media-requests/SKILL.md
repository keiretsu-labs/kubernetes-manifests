---
name: Media Requests
description: >
  Search, request, and manage media (movies/TV shows) via the Jellyseerr API.

  Use when: Someone asks to request a movie or TV show, check request status,
  search for media, or manage pending requests. Also use when asked "what's
  available" or "can you get [title]".

  Don't use when: Checking if media services are healthy (use media-stack-health
  cron job). Don't use for download client management (qbittorrent, sabnzbd).

  Outputs: Search results, request confirmations, or request status updates.
requires: []
---

# Media Requests via Jellyseerr API

## Connection Details

- **Base URL:** `http://jellyseerr.media.svc.cluster.local:5055/api/v1`
- **Auth Header:** `X-Api-Key: $SEERR_API_KEY`
- **Context:** Use `--context ottawa-k8s-operator.keiretsu.ts.net` if running kubectl, but prefer direct curl since you have network access to the service CIDR.

## Quick Reference

### Search for media
```bash
curl -s "http://jellyseerr.media.svc.cluster.local:5055/api/v1/search?query=TITLE&page=1&language=en" \
  -H "X-Api-Key: $SEERR_API_KEY" | jq '.results[:5] | .[] | {id, mediaType, title: (.title // .name), year: (.releaseDate // .firstAirDate | split("-")[0]), overview: .overview[:100]}'
```

### Get movie details (by TMDB ID)
```bash
curl -s "http://jellyseerr.media.svc.cluster.local:5055/api/v1/movie/TMDB_ID" \
  -H "X-Api-Key: $SEERR_API_KEY" | jq '{title, status, releaseDate, mediaInfo: .mediaInfo.status}'
```

### Get TV show details (by TMDB ID)
```bash
curl -s "http://jellyseerr.media.svc.cluster.local:5055/api/v1/tv/TMDB_ID" \
  -H "X-Api-Key: $SEERR_API_KEY" | jq '{name, status, firstAirDate, seasons: [.seasons[] | {seasonNumber, episodeCount}], mediaInfo: .mediaInfo.status}'
```

### Request a movie
```bash
curl -s -X POST "http://jellyseerr.media.svc.cluster.local:5055/api/v1/request" \
  -H "X-Api-Key: $SEERR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"mediaId": TMDB_ID, "mediaType": "movie"}'
```

### Request a TV show (specific seasons)
```bash
curl -s -X POST "http://jellyseerr.media.svc.cluster.local:5055/api/v1/request" \
  -H "X-Api-Key: $SEERR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"mediaId": TMDB_ID, "mediaType": "tv", "seasons": [1, 2, 3]}'
```

### List pending requests
```bash
curl -s "http://jellyseerr.media.svc.cluster.local:5055/api/v1/request?filter=pending&take=20" \
  -H "X-Api-Key: $SEERR_API_KEY" | jq '.results[] | {id, type: .type, status: .status, media: .media.tmdbId, title: (.media.title // .media.name), requestedBy: .requestedBy.displayName}'
```

### List all requests
```bash
curl -s "http://jellyseerr.media.svc.cluster.local:5055/api/v1/request?take=20&skip=0" \
  -H "X-Api-Key: $SEERR_API_KEY" | jq '{total: .pageInfo.results, results: [.results[] | {id, status, mediaType: .type, title: (.media.title // .media.name)}]}'
```

### Approve a request
```bash
curl -s -X POST "http://jellyseerr.media.svc.cluster.local:5055/api/v1/request/REQUEST_ID/approve" \
  -H "X-Api-Key: $SEERR_API_KEY"
```

### Decline a request
```bash
curl -s -X POST "http://jellyseerr.media.svc.cluster.local:5055/api/v1/request/REQUEST_ID/decline" \
  -H "X-Api-Key: $SEERR_API_KEY"
```

### Delete a request
```bash
curl -s -X DELETE "http://jellyseerr.media.svc.cluster.local:5055/api/v1/request/REQUEST_ID" \
  -H "X-Api-Key: $SEERR_API_KEY"
```

### Check server status
```bash
curl -s "http://jellyseerr.media.svc.cluster.local:5055/api/v1/status" \
  -H "X-Api-Key: $SEERR_API_KEY"
```

## Workflow

1. **Search** — always search first to get the TMDB ID
2. **Check details** — verify it's the right title and check if already available/requested
3. **Request** — create the request using the TMDB ID
4. **Confirm** — report back with the request status

## Media Status Codes

| Status | Meaning |
|--------|---------|
| 1 | Unknown |
| 2 | Pending |
| 3 | Processing |
| 4 | Partially Available |
| 5 | Available |

## Request Status Codes

| Status | Meaning |
|--------|---------|
| 1 | Pending Approval |
| 2 | Approved |
| 3 | Declined |

## Notes

- The `mediaId` in requests is always the **TMDB ID**, not an internal ID.
- Jellyseerr auto-routes requests to the appropriate Sonarr/Radarr instance (1080p, 4k, anime, etc.) based on its internal server configuration.
- The API key is available as `$SEERR_API_KEY` environment variable.
- Jellyseerr is publicly accessible at `jellyseerr.killinit.cc` and internally at `jellyseerr.media.svc.cluster.local:5055`.
- Both Jellyseerr (Ottawa) and Overseerr (Ottawa) run Seerr v3.1.0 with the same API.
