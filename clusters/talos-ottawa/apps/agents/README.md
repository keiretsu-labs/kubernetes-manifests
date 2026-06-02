# Personal Agents (Hermes)

Per-persona Hermes (`nousresearch/hermes-agent`) deployments. Each agent is a
self-contained Deployment + Tailscale LoadBalancer + Garage-backed PVC, with
its own Tailscale identity tagged `tag:raj` so only `rajsinghtech@github` can
reach it.

## Current agents

| Persona       | Tailscale hostname | Purpose                              |
| ------------- | ------------------ | ------------------------------------ |
| assistant-raj | `assistant-raj`    | Calendar / email / notes / reminders |
| abtar         | `abtar`            | Calendar / email / notes / reminders |

Reach it from your tailnet:

- Dashboard (HTTP): `http://assistant-raj`
- Hermes gateway API: `http://assistant-raj:8642` (bearer `${DEFAULT_PASSWORD}`)

## LLM backend

Points at `aperture.keiretsu.ts.net` (Qwen) via the `common-egress`
ProxyGroup. Configured in `app/assistant-raj/configmap.yaml`:

```
OPENAI_BASE_URL=http://aperture/v1
OPENAI_API_KEY=unused
```

## S3 storage

All agents share the `agents` Garage bucket (`app/bucket.yaml`). Each agent
has its own `GarageKey` (with owner perms on the bucket) so credentials can
be revoked per-agent.

## ACL

`tag:raj` is owned by `rajsinghtech@github`. Only `rajsinghtech@github` (and
peer `tag:raj` agents) can talk to it. Defined in `tailscale/policy.hujson`.

## Adding another agent

1. `cp -r app/assistant-raj app/<new-name>`
2. `grep -rl assistant-raj app/<new-name>/ | xargs sed -i '' 's/assistant-raj/<new-name>/g'`
3. Edit `configmap.yaml` — rewrite `AGENT_SYSTEM_PROMPT`, add persona env.
4. Fill `secret.sops.yaml` with real values, then
   `sops --encrypt --in-place app/<new-name>/secret.sops.yaml`.
5. Append `- <new-name>` to `app/kustomization.yaml`.
6. Add the new `GarageKey` to `app/bucket.yaml` keyPermissions.
7. Commit → Flux reconciles within 30 min.

## Files per agent

```
app/<name>/
├── kustomization.yaml
├── deployment.yaml           # Hermes gateway + dashboard
├── service.yaml              # ClusterIP
├── service-tailscale.yaml    # type: LoadBalancer, loadBalancerClass: tailscale, tag:raj
├── storagestack.yaml         # PVC + nightly Garage backup
├── garagekey.yaml            # S3 creds → Secret <name>-s3
├── egress.yaml               # ExternalName Tailscale egress (e.g. aperture)
├── configmap.yaml            # Persona prompt + Hermes/LLM env
└── secret.sops.yaml          # Per-agent integration secrets (Discord/Google/Notion)
```
