# kubernetes-manifests-bot-viewer

Read-only cluster identity for the Bhaiya V2 bot `kubernetes-manifests`.

## What this grants
- ServiceAccount `bhaiya/kubernetes-manifests-bot-viewer`
- ClusterRole with get/list/watch only (core, apps, Flux, Gateway, metrics)
- Bound only to that ServiceAccount

No create/update/patch/delete/exec. Manifest changes still go through PRs here.

## Durable kubeconfig Secret

Flux creates the metadata-only Secret `bhaiya/bh-b-wwhxmfbs-kubeconfig`. A
CronJob reads only `token` and `ca.crt` from
`kubernetes-manifests-bot-viewer-token`, builds a kubeconfig for
`https://kubernetes.default.svc`, and patches only `data.config` on that one
Secret every five minutes. The credential never enters Git, a ConfigMap, job
arguments, or logs. The sync ServiceAccount can patch only the named target
Secret; it cannot read Secrets through the API or change cluster resources.

After the ExtraSecretMounts allowlist is enabled in the Bhaiya control-plane
Deployment, the bot receives that Secret read-only at `/workspace/.kube/config`.
Use `KUBECONFIG=/workspace/.kube/config kubectl ...` from inside the bot. The
existing in-bot `get`-allowed / `create`-denied viewer RBAC remains the source
of authority. Flux still owns cluster changes; use PRs and normal GitOps.

The PVC copy currently in the bot remains compatible until the deployment
allowlist is enabled. The mount activation follows successful Secret sync so a
required Secret volume never makes the Computer fail to start while the target
key is absent.

## Follow-ups
- Replace the long-lived Secret with a TokenRequest broker / bot secret once that API exists.
- Do not add this SA to `tailnet-readers-ops` (that group can patch Deployments/Flux).

## API server egress

`apiserver-egress.yaml` adds a Cilium allow to entity `kube-apiserver` for
computer slug `b-wwhxmfbs`. Without it, in-pod kubectl to
`https://kubernetes.default.svc` times out even with a valid viewer kubeconfig.

`sync-egress.yaml` separately lets only the credential sync Job reach the
Kubernetes API to patch its one Secret. It does not widen the bot's read-only
authorization or network policy.
