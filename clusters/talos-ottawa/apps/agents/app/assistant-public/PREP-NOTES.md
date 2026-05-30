# assistant-public — gVisor-sandboxed public agent (PREP NOTES)

Branch: `agents-assistant-public-gvisor` (rebased on main @ 9c892a27a).
gVisor runtime + RuntimeClass now land cluster-wide via Raj's commit
(`clusters/common/apps/gvisor` + talconfig extension on all nodes). This branch
just consumes the `gvisor` RuntimeClass — it no longer defines its own.

## What's done (pure GitOps, in this branch)
```
clusters/talos-ottawa/apps/agents/app/
├── kustomization.yaml            # + assistant-public  (RuntimeClass now from common/apps/gvisor)
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
Note: deployment keeps `nodeSelector: workload-class=specialized` (pins to shiro,
off the control-plane nodes). gVisor is on all nodes now, so this is preference,
not a requirement.

## Step 1 — Talos gVisor extension — DONE upstream (commit 9c892a27a)
Added `siderolabs/gvisor` to all schematics + `user.max_user_namespaces=11255`
sysctl (required: Talos KSPP-defaults it to 0, runsc needs unprivileged userns) +
bumped to Talos v1.13.3. STILL REQUIRES the nodes to be upgraded/rebooted to pick
up the new schematic, then verify:
```bash
cd clusters/talos-ottawa && mise install && task genconfig
task upgrade node=192.168.169.116 image=<factory installer url from clusterconfig/*shiro*.yaml>
export KUBECONFIG=$HOME/.kube/operator-config
kubectl --context ottawa get node shiro -o jsonpath='{.status.runtimeHandlers[*].name}{"\n"}'  # want: runc runsc
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
