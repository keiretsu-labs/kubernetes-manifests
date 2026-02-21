# Operational Memory

Curated knowledge from past audit sessions. Update when you discover new patterns or gotchas.

## Validation Pitfalls

- `kustomize build` fails silently on missing files — always cross-check `resources[]` against actual files
- `configMapGenerator` files list must include `cron-jobs.json` alongside `openclaw.json`
- YAML anchors in deployment.yaml don't survive kustomize — use explicit values

## Config Escaping

- Flux postBuild substitutes all `${VAR}` — repo files must use `$${VAR}` for OpenClaw's own env resolution
- Double-check all `apiKey` fields in openclaw.json for correct escaping after edits

## SOPS Credential Patterns

- **PGP key:** `FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5` — stored in `sops-gpg` Secret per cluster
- **Cross-cluster secrets:** `clusters/common/flux/vars/common-secrets.sops.yaml` (DEFAULT_PASSWORD, CLOUDFLARE_*, TS_*, GARAGE_*, etc.)
- **Per-cluster secrets:** `clusters/talos-*/flux/vars/cluster-secrets.sops.yaml` (QB_WIREGUARD_*, SMB_*, app-specific API keys)
- **Substitution chain:** SOPS file → Flux decrypts → K8s Secret in flux-system → postBuild replaces `${VAR}` in child manifests
- **Three delivery patterns:**
  1. Inline substitution in HelmRelease values (e.g., unpoller `pass = "Keiretsu${DEFAULT_PASSWORD}0"`)
  2. Substituted Secret template → `secretKeyRef` (e.g., cloudflare secret.yaml with `${KILLINIT_CC_CLOUDFLARE_API_TOKEN}`)
  3. Direct `secretKeyRef` from operator-managed secrets (e.g., CNPG creates `coder-db-url`)
- **Opt-out label:** `substitution.flux.home.arpa/disabled: "true"` skips postBuild substitution
- See `skills/sops-credentials/SKILL.md` for full reference

## Container Facts

- Container name: `openclaw` (not `main`)
- Init containers: `sysctler`, `init-workspace`
- Config path: `/home/node/.openclaw/clawdbot.json` (emptyDir, writable)
- Workspace path: `/home/node/.openclaw/workspaces/<agent>/`

## CI Patterns

- Push method: `skopeo copy docker-archive:` only (Zot rejects docker push)
- Multi-arch: `crane index append` after per-arch skopeo pushes
- Base image: `ghcr.io/openclaw/openclaw:2026.2.9`

## Skill Design Patterns

- Skill descriptions should function as routing logic (when to use / when NOT to use)
- Negative examples ("Don't use when...") reduce misfires between similar skills
- Templates and examples inside skills are free when the skill isn't invoked
- Design for compaction: write findings to `/tmp/outputs/` as you go
- Standard artifact path: `/tmp/outputs/<task>.md`

## Alert Handling

### Cluster Label Key

**Use `cluster` label** for routing alerts to the correct kubectl context. This is the standard label from AlertManager for multi-cluster setups.

### Multi-Cluster Context Selection

Pattern: **when alert arrives → parse `cluster` label → use appropriate kubectl context**

```bash
# Extract cluster from alert (e.g., alert has labels: cluster=ottawa, alertname=PodCrashLoopBackOff)
CLUSTER_LABEL=$(echo "$ALERT_JSON" | jq -r '.labels.cluster')

# Use the cluster label to select kubectl context
kubectl config use-context $CLUSTER_LABEL

# Run diagnostics on the correct cluster
kubectl --context=$CLUSTER_LABEL get pods -n openclaw
flux --context=$CLUSTER_LABEL get kustomization -A
```

### Available Cluster Contexts

The workspace kubeconfig includes these contexts:
- `ottawa` - Primary cluster
- `robbinsdale` - Secondary cluster  
- `stpetersburg` - Tertiary cluster

### Alert Routing Flow

1. **Receive alert** → Parse JSON payload from AlertManager
2. **Extract cluster** → `cluster=$(echo $alert | jq -r '.labels.cluster')`
3. **Validate context** → `kubectl config get-contexts $cluster`
4. **Switch context** → `kubectl config use-context $cluster`
5. **Run diagnostics** → Use the alert-type-specific commands from EVENTS.md
6. **Report findings** → Send to Discord with cluster context noted
