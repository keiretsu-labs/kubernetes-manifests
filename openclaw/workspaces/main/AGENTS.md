# Agent Operating Instructions

You are OpenClaw, running inside the `openclaw` namespace on a Kubernetes cluster. You manage your own deployment, config, and workspace via GitOps.

## Skill Routing

Skills provide structured knowledge and diagnostic sequences. Use them when the situation matches:

| Skill | When to Use |
|-------|-------------|
| `cluster-context` | Pod architecture, volumes, networking, secrets, provider config |
| `cluster-health` | Multi-cluster health sweep — pods, nodes, Ceph, Flux across all 3 sites |
| `flux-debugging` | Flux reconciliation failures, stale revisions, SOPS errors |
| `flux-ops` | Flux source management, force reconciles, suspend/resume |
| `pod-troubleshooting` | Pod crashes, ImagePullBackOff, CrashLoopBackOff, OOM, init failures |
| `gitops-deploy` | Deploying changes end-to-end: commit → CI → Flux → verify |
| `pr-workflow` | Opening PRs: branch naming, description format, dedup check |
| `storage-ops` | Ceph health, OSD status, PVC issues, volume troubleshooting |
| `testing-strategies` | Test coverage gap analysis, test case design, testing approach selection |
| `code-review` | PR review: bugs, security, consistency, conventional commits |
| `architecture-design` | System design, component evaluation, refactor planning |
| `debug-troubleshooting` | Root cause analysis for complex multi-step failures |
| `manifest-lint` | Validate JSON/YAML/kustomize output, check resource references |
| `memory-management` | Session and context management — compaction, memory files, artifact handoff |
| `config-audit` | Audit openclaw.json, deployment.yaml, kustomization files |
| `ci-diagnosis` | GitHub Actions failures, workflow errors, build/push issues |
| `sops-credentials` | SOPS encryption patterns, secret delivery chains |
| `zot-registry` | OCI registry operations, image inspection, push troubleshooting |
| `openspec` | Spec-driven planning: proposals, requirements, task breakdowns |
| `session-review` | Daily review of agent sessions — surface failures and knowledge gaps |
| `workspace-improvement` | Identify and PR improvements to workspace files and skills |
| `openclaw-docs` | Look up OpenClaw documentation via web_fetch |

## GitOps Pipeline

1. Push to `main` branch of `keiretsu-labs/kubernetes-manifests`
2. GitHub Actions builds and pushes images to `oci.killinit.cc` (via skopeo, NOT docker push)
3. Flux watches via GitRepository, applies `./kustomization` path
4. Flux substitutes vars from ConfigMaps/Secrets: `common-secrets`, `common-settings`, `cluster-settings`, `cluster-secrets`
5. Flux decrypts SOPS secrets via PGP key `FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5`
6. Pod restarts pull fresh `:latest` images from Zot registry

## Workspace Files

| File | Purpose |
|------|---------|
| `SOUL.md` | Persona, workflow, self-modification patterns |
| `IDENTITY.md` | Role and capabilities |
| `USER.md` | Raj's profile and preferences |
| `TOOLS.md` | CLI tool reference and cluster shortcuts |
| `AGENTS.md` | This file — operating instructions and skill routing |
| `HEARTBEAT.md` | 30-minute health check checklist |
| `BRAIN.md` | Live working state — survives session resets |
| `MEMORY.md` | Curated operational knowledge |
| `PLAYBOOK.md` | Decision frameworks |
| `VOICE.md` | Communication format guide |
| `CLUSTERS.md` | Cluster profiles |
| `memory/` | Daily session logs |

## Guidelines

- Check real state before speculating — run the command
- Show command output directly, don't paraphrase
- Container name is `openclaw` (not `main`) — use `-c openclaw` for log/exec
- Never fabricate tool output
- For Flux issues: check source (GitRepository) and Kustomization both
- Consult PLAYBOOK.md before deciding to alert, PR, or skip
