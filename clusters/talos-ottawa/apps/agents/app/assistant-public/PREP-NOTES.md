# assistant-public — gVisor-sandboxed public agent (PREP NOTES)

Branch: `agents-assistant-public-gvisor`. Flux-side is built and validated.
The ONLY remaining build step requires the real talconfig + node access (you, at home).

## What's done (pure GitOps, in this branch)
```
clusters/talos-ottawa/apps/agents/app/
├── kustomization.yaml            # + runtimeclass-gvisor.yaml, + assistant-public
├── runtimeclass-gvisor.yaml      # RuntimeClass gvisor -> handler runsc (NEW)
├── bucket.yaml                   # + assistant-public-s3-key owner perms
└── assistant-public/             # NEW persona dir
    ├── kustomization.yaml
    ├── deployment.yaml           # runtimeClassName: gvisor; userspace TS sidecar; NO insecure dashboard
    ├── service.yaml              # ClusterIP (Gateway backend)
    ├── httproute.yaml            # ts+private+public -> assistant.keiretsu.top -> :9119
    ├── storagestack.yaml         # 20Gi ceph-block + nightly Garage backup
    ├── garagekey.yaml            # per-agent S3 creds
    ├── configmap.yaml            # PUBLIC-hardened (allow-all off, real API key, no insecure)
    ├── ts-auth.yaml              # TS_AUTHKEY from ${TS_OAUTH_CLIENT_SECRET} (SOPS var-sub)
    ├── ts-serve-config.yaml      # `tailscale serve` -> dashboard on tailnet identity
    └── secret.sops.yaml.example  # COPY -> secret.sops.yaml, fill, ENCRYPT, uncomment in kustomization
```
Note: NO `service-tailscale.yaml` — the operator LoadBalancer is intentionally
replaced by the in-pod full-fat Tailscale client.
Note: NO `egress.yaml` — the `stpetersburg-vllm` ExternalName already exists once
in the shared `agents` namespace (defined by assistant-raj) and is reused.

## Remaining step 1 — Talos: add gVisor extension to shiro (NEEDS YOUR TALCONFIG + node access)
File: `clusters/talos-ottawa/bootstrap/talos/talconfig.yaml`, shiro's block (~line 104).
Add `siderolabs/gvisor` to shiro's `officialExtensions`:

```yaml
  - hostname: "shiro"
    ...
    schematic:
      customization:
        systemExtensions:
          officialExtensions:
            - siderolabs/i915
            - siderolabs/intel-ucode
            - siderolabs/nut-client
            - siderolabs/util-linux-tools
            - siderolabs/gvisor      # <-- ADD: ships runsc + registers io.containerd.runsc.v1
```

Then regenerate + upgrade JUST shiro (changing extensions changes the schematic ID,
which requires an installer-image upgrade = one reboot of the worker):

```bash
cd clusters/talos-ottawa
mise install                                   # talhelper, talosctl, sops, task
task genconfig                                 # talhelper genconfig (renders clusterconfig/)
# Get the NEW schematic-pinned installer image for shiro from the rendered config:
talosctl --nodes 192.168.169.116 upgrade \
  --image $(grep -m1 'image:.*installer' clusterconfig/*shiro*.yaml | awk '{print $2}') \
  --preserve=true --wait=true --timeout=10m
# (or use the Taskfile: `task upgrade node=192.168.169.116 image=<factory installer url>`)
```
`--preserve=true` keeps the node's data; only the OS image (with the extension) changes.

Verify after reboot:
```bash
export KUBECONFIG=$HOME/.kube/operator-config
kubectl --context ottawa get node shiro -o jsonpath='{.status.runtimeHandlers[*].name}{"\n"}'
# want: runc runsc
```

## Remaining step 2 — secrets
1. Confirm the Tailscale OAuth client behind `${TS_OAUTH_CLIENT_SECRET}` (in
   common-secrets) is scoped to assign **tag:raj**. If not, widen it in the TS
   admin console or mint a client that can, else `--advertise-tags=tag:raj` fails.
2. Decide the public API key wiring: either add `ASSISTANT_PUBLIC_API_KEY` to the
   SOPS `common-secrets` (keeps configmap var-sub as written), OR inline a strong
   key directly into `assistant-public/secret.sops.yaml` and change the configmap
   to read it from the secret. Then:
   `sops --encrypt --in-place clusters/talos-ottawa/apps/agents/app/assistant-public/secret.sops.yaml`
3. Add DNS A record `assistant.keiretsu.top` via the ddup/k8gb path (other public hosts).

## Remaining step 3 — validate, PR, reconcile
```bash
KUBERNETES_VERSION=1.36.1 kustomize build --enable-helm clusters/talos-ottawa/apps/agents/app >/dev/null
git push -u origin agents-assistant-public-gvisor   # PR -> Claude review + kustomize-validate Actions
# after merge:
flux reconcile kustomization agents -n flux-system
```
Verify HTTPRoute accepted public: `kubectl --context ottawa get httproute assistant-public -n agents -o jsonpath='{range .status.parents[*]}{.parentRef.name}={.conditions[?(@.type=="Accepted")].status} {end}'`

## Open decisions still yours
- API key location (common-secrets var vs inline secret).
- Real SSO in front of the dashboard for public (pocket-id/oauth2-proxy) — stubbed, not wired.
- Whether to also migrate assistant-raj to this pattern, or leave it on the operator LB.
