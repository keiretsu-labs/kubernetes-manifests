# Gilfoyle Autonomous SRE CronJob — Design

**Date:** 2026-02-19
**Status:** Approved

## Overview

Deploy [axiomhq/gilfoyle](https://github.com/axiomhq/gilfoyle) as an autonomous AI-powered SRE CronJob
on the common cluster, following the same GitOps pattern as swarm. Gilfoyle runs every 4 hours,
queries the cluster observability stack via its shell scripts, drives Claude AI analysis via the
Anthropic API, and outputs findings to stdout with Discord alerting on critical/high severity events.

## Architecture

```
/gilfoyle/
├── Dockerfile              # node:22-bookworm-slim, Gilfoyle skill baked in at build time
├── Makefile                # docker-build, docker-push (mirrors swarm)
├── run.mjs                 # ESM entry point: Claude API + tool execution loop
└── kustomization/
    ├── namespace.yaml
    ├── kustomization.yaml
    ├── cronjob.yaml        # 0 */4 * * *
    ├── configmap.yaml      # Gilfoyle config.toml (Grafana/VictoriaLogs in-cluster endpoints)
    └── secret.sops.yaml    # ANTHROPIC_API_KEY, GRAFANA_SA_TOKEN, DISCORD_WEBHOOK_URL

/clusters/common/apps/gilfoyle/
├── namespace.yaml
├── ks.yaml                 # Flux Kustomization → ./gilfoyle/kustomization
└── kustomization.yaml
```

## Observability Stack

Gilfoyle connects to the existing in-cluster monitoring (Grafana Operator-managed):

| Tool | In-cluster endpoint | Purpose |
|------|---------------------|---------|
| Grafana | `grafana-service.monitoring:3000` | Alerts, dashboards, datasource proxy |
| Prometheus | `kube-prometheus-stack-prometheus.monitoring:9090` | Metrics (via Grafana datasource) |
| VictoriaLogs | `victoria-logs-victoria-logs-single-server.monitoring:9428` | Logs (via Grafana VictoriaLogs plugin) |
| Alertmanager | `kube-prometheus-stack-alertmanager.monitoring:9093` | Active alert enumeration |

No Axiom, Pyroscope, or Slack — Grafana is the sole data entry point with Prometheus and
VictoriaLogs as backend datasources.

## run.mjs Execution Flow

1. Write `~/.config/gilfoyle/config.toml` from env vars (`GRAFANA_URL`, `GRAFANA_SA_TOKEN`)
2. Run `scripts/init` — discovers Grafana datasources and alert rules
3. POST to Anthropic `messages` API:
   - System: Gilfoyle `SKILL.md` content (baked into image at `/gilfoyle/SKILL.md`)
   - User: *"Investigate cluster health in the last 4 hours. Check active alerts, error rates, anomalous log patterns. Summarize with severity."*
4. Loop over response blocks:
   - `text` → accumulate
   - `tool_use` → `execSync` the corresponding Gilfoyle script, return stdout as `tool_result`
5. Repeat until no more `tool_use` blocks (stop_reason: `end_turn`)
6. Print final report to stdout
7. If report contains Critical or High severity → POST Discord webhook

## Dockerfile

- Base: `node:22-bookworm-slim`
- System packages: `bash curl jq coreutils git ca-certificates`
- Gilfoyle skill: cloned at build time (`git clone --depth=1 https://github.com/axiomhq/gilfoyle /gilfoyle-src`, copy `skill/` to `/gilfoyle/`)
- App: `COPY run.mjs /app/run.mjs`
- User: `node` (UID 1000, non-root)
- Working dir: `/app`

## Kubernetes Resources

**CronJob** (`cronjob.yaml`):
- Schedule: `0 */4 * * *`
- `restartPolicy: OnFailure`
- `backoffLimit: 2`
- `successfulJobsHistoryLimit: 3`
- `failedJobsHistoryLimit: 3`
- Security context: `runAsNonRoot: true`, `runAsUser: 1000`, all capabilities dropped, `seccompProfile: RuntimeDefault`
- Resources: requests 50m/128Mi, limits 256Mi (no CPU limit)
- Image: `oci.${CLUSTER_DOMAIN}/gilfoyle/gilfoyle:latest`, `imagePullPolicy: Always`
- Env from secret: `ANTHROPIC_API_KEY`, `GRAFANA_SA_TOKEN`, `DISCORD_WEBHOOK_URL`
- Env from configmap: `GRAFANA_URL`, `VICTORIA_LOGS_URL`, `ALERTMANAGER_URL`

**ConfigMap** (`configmap.yaml`): Gilfoyle `config.toml` template with Flux-substituted in-cluster URLs

**Secret** (`secret.sops.yaml`): SOPS-encrypted (PGP FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5)
- `ANTHROPIC_API_KEY` — Claude API key
- `GRAFANA_SA_TOKEN` — Grafana service account token (created out-of-band)
- `DISCORD_WEBHOOK_URL` — Alert channel webhook

## Flux Kustomization

- Path: `./gilfoyle/kustomization`
- No `dependsOn` (no Temporal dependency unlike swarm)
- Same variable substitution pattern as swarm (`common-settings`, `common-secrets`, `cluster-settings`, `cluster-secrets`)
- SOPS decryption via `sops-gpg` secret in `flux-system`

## Grafana Service Account

A Grafana service account token with `Viewer` role must be created manually in Grafana
(or via Grafana API) and stored in the SOPS secret. Viewer is sufficient — Gilfoyle only reads.

## Non-Goals

- No HTTP API / UI (CronJob, not Deployment)
- No Tailscale tsnet integration (Grafana is reachable in-cluster; no cross-cluster queries)
- No persistent state (each run is independent; history in pod logs)
- No Axiom / Pyroscope (not deployed in this cluster)
