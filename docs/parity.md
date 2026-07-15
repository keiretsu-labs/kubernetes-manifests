# kubernetes-manifests parity tracker

Feature gap analysis vs desired target state. Status: ✅ done · 🔶 partial ·
🚧 in progress · ⬜ not started.

## Tier 1: Core GitOps compliance

| Feature | Status | Notes |
| --- | --- | --- |
| Flux base + overlay model | ✅ | Standardized across all apps |
| SOPS encryption for secrets | ✅ | PGP key FAC8E7C3... |
| `make test` passes (flate render) | ✅ | Validates all clusters |
| Variable substitution (common/cluster settings) | ✅ | `substituteFrom` stack |
| Multi-cluster app pointers | ✅ | One pointer per location overlay |

## Tier 2: Build-agent tooling

| Feature | Status | Notes |
| --- | --- | --- |
| `tools/agent/pi-task.sh` | ✅ | pi harness: watchdog + 503 retry + session harvest |
| `tools/check.sh` acceptance gate | ✅ | CI-matching render validation |
| `tools/where.sh` line locator | ✅ | Avoids re-reading large files |
| `tools/app.sh` app locator | ✅ | Base dir + clusters that deploy an app |
| `tools/wait-build.sh` | ✅ | Background process poller |
| `docs/reference/app-template.md` | ✅ | Copy-paste new-app skeleton |
| `docs/toolsmith.md` | ✅ | Tools improvement instructions |
| `docs/prompt-notes.md` | ✅ | Prompt patterns log |
| `docs/parity.md` (this file) | ✅ | Feature gap tracker |

## Tier 3: Cluster coverage

| Location | Status | Notes |
| --- | --- | --- |
| Ottawa (talos-ottawa) | ✅ | Primary: media, databases, Rook-Ceph |
| Robbinsdale (talos-robbinsdale) | ✅ | Home automation, Rook-Ceph |
| St. Petersburg (talos-stpetersburg) | ✅ | AI/ML: GPU operator, KServe, Ray |

## Tier 4: App categories

| Category | Status | Notes |
| --- | --- | --- |
| Platform/GitOps (flux, cert-manager, external-secrets) | ✅ | Core infra |
| Networking (Cilium, Envoy Gateway, k8gb, spiderpool) | ✅ | Multi-cluster networking |
| Storage (Rook-Ceph, Garage, CNPG, Dragonfly) | ✅ | Persistent + object + DB |
| Observability (Prometheus, Grafana, Mimir, Tempo, Loki) | ✅ | Metrics + traces + logs |
| Registry/CI (Zot, Forgejo, Woodpecker, GHA runners) | ✅ | Container registry + CI |
| Media (Jellyfin, Plex, *arr, qBittorrent, etc.) | ✅ | Full media stack all locations |
| Home (Homer, Home Assistant, Immich, TeslaMate) | ✅ | Home automation |
| AI/ML (Ollama, KServe, Ray, GPU Operator) | ✅ | St. Petersburg only |
| Tailscale (operator, Connector, Recorder, DNSConfig) | ✅ | Full operator integration |

## Tier 5: Build-agent workflow maturity

- [ ] Regular toolsmith pass after every 3-5 changes
- [ ] `docs/prompt-notes.md` kept current with each session's lessons
- [ ] Agent prompts include all known gotchas from prompt-notes
- [ ] All phases verified with `tools/check.sh` before commit
- [ ] Copy-paste templates in `docs/reference/` for repeated workflows
