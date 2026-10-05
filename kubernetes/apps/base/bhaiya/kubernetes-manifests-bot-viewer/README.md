# kubernetes-manifests-bot-viewer

Read-only cluster identity for the Bhaiya V2 bot `kubernetes-manifests`.

## What this grants
- ServiceAccount `bhaiya/kubernetes-manifests-bot-viewer`
- ClusterRole with get/list/watch only (core, apps, Flux, Gateway, metrics)
- Bound only to that ServiceAccount

No create/update/patch/delete/exec. Manifest changes still go through PRs here.

## Delivering the kubeconfig to the bot
After Flux reconciles Ottawa:

```bash
# on an operator host with Ottawa kubectl (tools/kc.sh ot)
TOKEN=$(tools/kc.sh ot -n bhaiya get secret kubernetes-manifests-bot-viewer-token -o jsonpath='.data.token' | base64 -d)
CA=$(tools/kc.sh ot -n bhaiya get secret kubernetes-manifests-bot-viewer-token -o jsonpath='.data.ca\.crt')
# Write kubeconfig into the bot via bhaiyactl bots exec/cp (never print TOKEN).
```

Server URL: use the Ottawa operator API (`ottawa-k8s-operator.keiretsu.ts.net` or the in-repo kubeconfig server). Do not commit the token.

## Follow-ups
- Replace the long-lived Secret with a TokenRequest broker / bot secret once that API exists.
- Do not add this SA to `tailnet-readers-ops` (that group can patch Deployments/Flux).
