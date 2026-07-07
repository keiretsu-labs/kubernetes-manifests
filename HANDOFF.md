# ai-sre Handoff — July 7 2026

## TL;DR

Stripped netpols, fixed Holmes LLM model + readonly-fs crashes, switched Holmes
container to AG-UI server for Headlamp AI Assistant integration, wired up St.
Petersburg vLLM. Two commits pushed to `main`:
- `8658f1e32` — bulk simplification
- `f6f4e4499` — fix kustomize patch (strategic merge → JSON6902)

**One thing is still broken: the Ottawa HelmRelease won't roll because the
`holmes(app)/kustomization.yaml` JSON6902 patch is applied at kustomize build
time, but Helm applies its own rendered manifest which re-adds the original
httpGet probe alongside the tcpSocket probe → Kubernetes rejects it with
"may not specify more than 1 handler type".** This is the only blocker. Fix
is below in §1.

---

## Architecture (what ai-sre is supposed to be)

```
                      Headlamp (kube-system)
                          │ AI Assistant plugin (v0.2.0-alpha)
                          │ calls /api/v1/namespaces/ai-sre/services/holmes-holmes:80/proxy/api/agui/chat
                          ▼
  Ottawa cluster ─────────────────────────────────────────────
    ai-sre/holmes-holmes  ←── AG-UI server (server-agui.py) ──→ stpetersburg-vllm (ExternalName → Tailscale → )
    ai-sre/holmes-shim    ←── MCP multiplexer / webhooks ──┐    ai/vllm-ts (dsv4 DeepSeek-V4-Flash TP=2)
    ai-sre/woodpecker-mcp ←── k8s topology graph (Kuzu)
                           │   ↑
                           │   │ mimir-proxy sidecar (nginx) injects X-Scope-OrgID: talos-ottawa
                           │   │ so woodpecker reaches mimir-gateway.mimir:8080/prometheus
                           │
                           └──→ holmes-holmes:5050 (MCP server mode)

  St. Petersburg cluster ─────────────────────────────────────
    ai-sre/holmes-holmes  ←── read-agent (server.py, NOT AG-UI) ──→ vllm-ts.ai.svc (local)
    holmes-ts LoadBalancer ←── Tailscale ingress, hostname=stpetersburg-holmes

  Robbinsdale cluster ────────────────────────────────────────
    ai-sre/holmes-holmes  ←── read-agent (server.py) ──→ stpetersburg-vllm via Tailscale
    holmes-ts LoadBalancer ←── Tailscale ingress, hostname=robbinsdale-holmes

  Cross-cluster routing:
    Ottawa holmes-shim ConfigMap HOLMES_URLS =
      {"central":"http://holmes-holmes.ai-sre.svc:80",
       "robbinsdale":"http://robbinsdale-holmes.ai-sre.svc:80",
       "stpetersburg":"http://stpetersburg-holmes.ai-sre.svc:80"}
    The rbd/stp holmes-holmes services are ExternalName pointing at the
    Tailscale proxy-group services (holmes-ts in those clusters).
```

---

## Current live state (per cluster)

### Ottawa — `kubernetes-ottawa.keiretsu.ts.net`
- `holmes-holmes-66fc6b8c66-cxsrc` 1/1 Running, AG-UI server live: `curl localhost:5050/api/agui/chat/health` → `"ok"`
  - Was kubectl-patched live with: `MODEL=openai/deepseek-v4-flash`, `HOLMES_CONFIGPATH_DIR=/tmp/.holmes`, `OPENAI_API_BASE=http://stpetersburg-vllm.ai-sre.svc.cluster.local:80/v1`, command=`server-agui.py`, probes = tcpSocket
- `holmes-operator-7f78b8c5b6-wn59h` 1/1 Running — **should not exist** (operator.enabled=false in git) but Flux HelmRelease is stuck in rollback so Helm hasn't re-rendered. Will get pruned when §1 is fixed.
- `holmes-shim` 1/1 Running, MCP shim working (200 OK on /mcp)
- `woodpecker-mcp` 2/2 Running (woodpecker + mimir-proxy sidecar)
- Network policies all deleted from cluster manually — gone.
- `holmes-shim-ts` LoadBalancer (100.96.199.228) on tailnet as `ottawa-holmes-mcp`
- `holmes-mcp.killinit.cc` DNSEndpoint → 10.169.10.14 (private gateway)
- ❌ **`helmrelease holmes` READY=False** — stuck in rollback loop. See §1.

### St. Petersburg — `kubernetes-stpetersburg.keiretsu.ts.net`
- `holmes-holmes-c454597cf-q5fmd` 1/1 Running (read-agent, port 5050)
  - Kubectl-patched live with the env fixes (openai/ prefix + HOLMES_CONFIGPATH_DIR)
- `holmes-holmes-7b4756b544-rsxlw` 1/1 Running — newer pod from a different ReplicaSet; check for stale RS garbage. Both pods might be up due to Helm rollback weirdness.
- `holmes-ts` LoadBalancer (100.122.194.227) on tailnet as `stpetersburg-holmes`
- `stpetersburg-vllm` ExternalName → `vllm-ts.ai.svc.cluster.local` (local vLLM, no Tailscale roundtrip)
- woodpecker-mcp **deleted** (was arm64-broken: image is amd64-only, stp cluster is DGX Spark/arm64)
- ❌ Cluster has unrelated infra problems: `kube-scheduler-orin-0` CrashLoopBackOff, `kube-controller-manager-orin-0` CrashLoopBackOff, `cilium-operator-85fdb9448f-kznr4` CrashLoopBackOff, nodes at 96-99% memory. **NOT an ai-sre issue.**

### Robbinsdale — `kubernetes-robbinsdale.keiretsu.ts.net`
- `holmes-holmes-7b4756b544-fwdhw` 1/1 Running (read-agent)
- `woodpecker-mcp-fcb4fbfcd-wfwlm` 2/2 Running
- Looks healthy. Reconciled cleanly after the push.

---

## Open issues — in priority order

### 1. (BLOCKER) Ottawa Holmes HelmRelease won't reconcile

**Symptom:**
```
helmrelease holmes READY=False
"Helm rollback to previous release ai-sre/holmes.v12 with chart holmes@0.35.0
 failed: server-side apply failed for object ai-sre/holmes-holmes apps/v1,
 Kind=Deployment: Deployment.apps 'holmes-holmes' is invalid:
 [spec.template.spec.containers[0].livenessProbe.tcpSocket: Forbidden: may
  not specify more than 1 handler type,
  spec.template.spec.containers[0].readinessProbe.tcpSocket: Forbidden: may
  not specify more than 1 handler type]"
```

**Cause:** The kustomize JSON6902 patch in `kubernetes/apps/base/ai-sre/holmes/app/kustomization.yaml`
uses `op: replace` on `/livenessProbe` and `/readinessProbe`. Kustomize renders
this correctly (verified via `make test-talos-ottawa` — passes). But when
Helm's `server-side apply` posts the manifest, the live Deployment still has
the old `httpGet` probe key — Helm's strategic merge sees `tcpSocket` as a
new key and **adds** it without removing the old `httpGet`, producing a probe
with two handlers. Kubernetes rejects this.

Worse: because the chart's default values also set `livenessProbe.httpGet`,
even a clean install hits this — it's not just a stale-state problem.

**Fix options (pick one):**

**Option A — Override the chart's probes via Helm values** (recommended)
Instead of patching post-render, set the probes to `nil` in the HelmRelease
`values:` block and let kustomize add them. The chart exposes probe fields at:
```
helm/holmes/values.yaml — livenessProbe: {} (currently empty by default)
helm/holmes/templates/holmes.yaml:109-124 — hardcodes httpGet on /healthz
```
So the chart doesn't actually expose probe overrides via values. We need to
either:
  - **A1:** Open a PR upstream to HolmesGPT to make `livenessProbe`/`readinessProbe` overridable via values, then we set them to `{}` and use a kustomize patch to fill in tcpSocket. Cleanest long-term.
  - **A2:** Pre-render the chart with `helm template` and commit a raw Deployment manifest instead of using HelmRelease. Loses Helm's lifecycle management for Holmes but sidesteps the patch conflict.
  - **A3:** Use Flux's `postRender` kustomize patch instead of a kustomization.yaml patch — but Flux HelmRelease doesn't have a separate `postRender` field in v2; the kustomization.yaml in the chart source dir IS the post-render (via `spec.valuesFrom` and the chart's own kustomization). So this doesn't help.

**Option B — Make the AG-UI server expose /healthz and /readyz**
Instead of changing probes, change the server. `experimental/ag-ui/server-agui.py`
only has `/api/agui/chat/health` and `/api/model`. Add a top-level `/healthz`
and `/readyz` returning `{"status":"ok"}`. Then the chart's default httpGet
probes work without any patch. This is the **simplest fix** and benefits
upstream too. File: `/Users/rajsingh/Documents/GitHub/holmesgpt/experimental/ag-ui/server-agui.py`
around line 96 — just add:
  ```python
  @app.get("/healthz")
  async def healthz():
      return PlainTextResponse("ok")

  @app.get("/readyz")
  async def readyz():
      return PlainTextResponse("ok")
  ```
  Then rebuild the holmes image, push to `robustadev/holmes`, and remove the
  kustomize patch entirely. The HelmRelease will roll clean.

**Option C — Drop the AG-UI server entirely, use plain Holmes server.py**
We lose Headlamp AI Assistant integration (the whole reason for AG-UI).
Not recommended.

**Recommended path: Option B** — add `/healthz` + `/readyz` to the AG-UI server,
rebuild, remove the kustomize patch. The live Ottawa pod is already running
AG-UI with tcpSocket probes (kubectl-patched), so this is non-disruptive.

**Immediate workaround to unblock the HelmRelease until Option B lands:**
Just delete the stuck HelmRelease revision and let Flux re-apply:
```bash
# Ottawa
kubectl delete secret -n ai-sre holmes-holmes.v12  # the failed release secret
flux reconcile helmrelease holmes -n ai-sre
# If still failing, force:
helm uninstall holmes -n ai-sre
flux reconcile helmrelease holmes -n ai-sre
```
But this will fail again because the chart still ships httpGet probes — you must do Option B (or A1/A2) first.

### 2. (MED) `holmes-operator` Deployment lingers on Ottawa
Because the HelmRelease is stuck, `operator.enabled=false` never took effect.
Once §1 is fixed, Helm will prune it. Until then, `holmes-operator-7f78b8c5b6-wn59h`
keeps running and trying to call `/api/checks/execute` on the AG-UI server
(which 404s). Harmless but noisy in logs. Manual cleanup:
```bash
kubectl scale deploy -n ai-sre holmes-operator --replicas=0
```

### 3. (MED) St. Petersburg has stale Holmes ReplicaSets
Two holmes-holmes pods up from different ReplicaSets:
- `holmes-holmes-c454597cf-q5fmd` (older revision)
- `holmes-holmes-7b4756b544-rsxlw` (newer)

Clean up once §1 unblocks Helm:
```bash
kubectl --context stpetersburg scale rs -n ai-sre holmes-holmes-c454597cf --replicas=0
kubectl --context stpetersburg scale rs -n ai-sre holmes-holmes-58d695849d --replicas=0  # if exists
```

### 4. (LOW) stpetersburg cluster infra broken — separate from ai-sre
- `kube-scheduler-orin-0` CrashLoopBackOff (50+ restarts)
- `kube-controller-manager-orin-0` CrashLoopBackOff
- `cilium-operator-85fdb9448f-kznr4` CrashLoopBackOff
- Nodes spark-0/spark-1 at 96-99% memory requests
- Effect: holmes pods can go Pending due to scheduler being down, completely unrelated to ai-sre changes

Likely needs a Talos node reboot or etcd cleanup on orin-0. Check
`kubectl --context stpetersburg logs -n kube-system kube-scheduler-orin-0` for
the actual crash reason.

### 5. (LOW) `holmes-checks` FluxKustomization CR still exists on Ottawa (orphan)
I deleted `holmes-checks.yaml` from the Ottawa overlay git tree but the Flux
Kustomization CR is still in the cluster. It will error trying to reconcile
the deleted path. Prune it:
```bash
kubectl --context ottawa delete kustomization -n flux-system holmes-checks
```
Flux should prune this automatically once the parent reconciles since the
pointer file is gone, but it may take a cycle.

### 6. (LOW) `holmes-cross-cluster-egress.yaml` on Ottawa is stale
`kubernetes/apps/ottawa/ai-sre/holmes-cross-cluster-egress.yaml` defines
ExternalName services `robbinsdale-holmes` and `stpetersburg-holmes` pointing
at Tailscale tailnet-fqdns. These work and are correct. **No action needed**
but worth noting they exist — if cross-cluster investigate() calls stop
working, the Tailscale DNS is the chokepoint.

### 7. (LOW) `ScheduledHealthCheck` CRs are orphaned in Ottawa cluster
I deleted the `ScheduledHealthCheck` manifests from git but the live CRs
(`ceph-health`, `flux-reconcile-state`, `bhaiya-workspaces`, `mimir-ingest`)
still exist via the operator. Since the operator is being removed, these
will become orphans. Delete them:
```bash
kubectl --context ottawa delete scheduledhealthcheck -n ai-sre --all
kubectl --context ottawa delete healthcheck -n ai-sre --all  # if any
```

### 8. (INFO) HolmesGPT repo cloned
`/Users/rajsingh/Documents/GitHub/holmesgpt` — reference repo for:
- AG-UI server source: `experimental/ag-ui/server-agui.py`
- Holmes Helm chart: `helm/holmes/` (templates at `helm/holmes/templates/holmes.yaml`)
- Litellm/env_vars: `holmes/common/env_vars.py` (defines HOLMES_HOST, HOLMES_PORT=5050)
- Config path: `holmes/core/config.py:4` reads `HOLMES_CONFIGPATH_DIR` env, defaults to `~/.holmes`

### 9. (INFO) Headlamp plugins repo cloned
`/Users/rajsingh/Documents/GitHub/headlamp-plugins` — the `ai-assistant/`
plugin source. Notable:
- `src/agent/holmesClient.ts` — defaults to `holmesNamespace=default`,
  `holmesServiceName=holmesgpt-holmes`, `holmesPort=80`. **Our Ottawa service
  is `holmes-holmes` in namespace `ai-sre`** — user must set these in
  Headlamp UI → AI Assistant settings → Holmes Agent section, OR rebuild the
  plugin with updated defaults.
- `src/agent/holmesClient.ts` probes `/api/v1/namespaces/{ns}/services/{svc}:{port}/proxy`
  and treats 404/405/422 as "pod is up". The AG-UI server will return 404
  on `/` (no route), so the health check will pass.

---

## What's verified working

- ✅ Ottawa holmes pod: AG-UI server responds `"ok"` on `/api/agui/chat/health`
- ✅ Ottawa holmes env: `MODEL=openai/deepseek-v4-flash` (litellm loads it without error)
- ✅ Ottawa holmes writes to `/tmp/.holmes` (no more `OSError: [Errno 30] Read-only file system`)
- ✅ `stpetersburg-vllm.ai-sre.svc.cluster.local:80/v1/models` returns `deepseek-v4-flash` from both Ottawa (via Tailscale ExternalName) and St. Petersburg (local ExternalName → vllm-ts.ai)
- ✅ holmes-shim MCP endpoint returns 200 OK on `/mcp`
- ✅ woodpecker-mcp-token secret: real token, SOPS-encrypted with PGP `FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5`
- ✅ flate render test passes for ai-sre on all three clusters (`make test-talos-{ottawa,robbinsdale,stpetersburg}` — only pre-existing VPA/bhaiya/ai-inference failures, no ai-sre failures)
- ✅ Network policies/CiliumNetworkPolicies removed from git and from Ottawa cluster live
- ✅ Robbinsdale holmes + woodpecker-mcp reconcile cleanly after push

---

## File map — what changed

```
kubernetes/apps/base/ai-sre/
├── holmes/app/
│   ├── helmrelease.yaml          ← operator.enabled=false, MODEL=openai/..., HOLMES_CONFIGPATH_DIR=/tmp/.holmes
│   ├── kustomization.yaml        ← adds JSON6902 patch for command + tcpSocket probes
│   └── agui-command-patch.yaml   ← DELETED (patch is inline in kustomization.yaml now)
├── holmes-read-agent/app/
│   └── helmrelease.yaml          ← MODEL=openai/..., HOLMES_CONFIGPATH_DIR=/tmp/.holmes
├── holmes-shim/app/
│   ├── kustomization.yaml        ← removed netpol/egress refs
│   ├── networkpolicy.yaml        ← DELETED (was CiliumNetworkPolicy ingress)
│   └── egress.yaml               ← DELETED (was CiliumNetworkPolicy egress)
└── woodpecker-mcp/app/
    ├── kustomization.yaml        ← removed netpol/egress refs
    ├── networkpolicy.yaml        ← DELETED (was NetworkPolicy ingress)
    ├── egress.yaml               ← DELETED (was CiliumNetworkPolicy egress)
    └── secret.sops.yaml          ← real SOPS-encrypted token (was ENC[] placeholder)

kubernetes/apps/ottawa/ai-sre/
├── kustomization.yaml            ← removed holmes-checks
└── holmes-checks.yaml            ← DELETED

kubernetes/apps/stpetersburg/ai-sre/
├── kustomization.yaml            ← removed woodpecker-mcp
├── woodpecker-mcp.yaml           ← DELETED (arm64-broken image, no mimir on stp)
└── holmes.yaml                   ← removed dependsOn: woodpecker-mcp
```

---

## Reference: how Holmes + Headlamp AI Assistant are supposed to talk

The Headlamp `ai-assistant` plugin (`v0.2.0-alpha`, already in headlamp
HelmRelease initContainers) talks to Holmes via the **AG-UI protocol** over
SSE. The plugin calls:

```
POST /api/v1/namespaces/{ns}/services/{svc}:{port}/proxy/api/agui/chat
  ↑ this is the K8s API server service proxy ( Headlamp's kubeconfig has cluster-admin )
```

So Holmes must:
1. Run `experimental/ag-ui/server-agui.py` (not the default `server.py`)
2. Listen on port 5050 (it does by default)
3. Have `/api/agui/chat` route (server-agui.py defines this at line 101)
4. Be reachable via `holmes-holmes:80` Service in namespace `ai-sre`

User configuration step in Headlamp UI:
- AI Assistant settings → Holmes Agent → set:
  - Holmes Namespace: `ai-sre`
  - Holmes Service Name: `holmes-holmes`
  - Holmes Port: `80`

The plugin source lives at `/Users/rajsingh/Documents/GitHub/headlamp-plugins/ai-assistant/`.

---

## Reference: St. Petersburg vLLM wiring

The Holmes LLM calls go:
```
holmes pod env OPENAI_API_BASE=http://stpetersburg-vllm.ai-sre.svc.cluster.local:80/v1
   └─→ Service "stpetersburg-vllm" (ExternalName) in ai-sre namespace
        ├─ Ottawa/Robbinsdale: externalName=placeholder, annotated with
        │   tailscale.com/tailnet-fqdn=stpetersburg-vllm.keiretsu.ts.net +
        │   tailscale.com/proxy-group=common-egress → routed via Tailscale
        │   to the stpetersburg vllm-ts LoadBalancer
        └─ St. Petersburg: externalName=vllm-ts.ai.svc.cluster.local (local, no Tailscale)
```

The `vllm-ts` Service in the `ai` namespace on St. Petersburg:
- `type: LoadBalancer`, `loadBalancerClass: tailscale`
- Selector: `{app: dsv4, role: head}` — the DeepSeek-V4-Flash TP=2 LeaderWorkerSet
- Port 80 → targetPort 8000 (the vllm pod's http port)
- Defined in `kubernetes/apps/base/ai/ai/inference/vllm.yaml` and `dsv4.yaml` (note: there's a
  duplicate `vllm-ts` Service between `vllm.yaml` and `dsv4.yaml` that causes a pre-existing
  flate render error — `make test-talos-stpetersburg` shows it but it's not from ai-sre)

vLLM models verified live (both clusters):
```
GET /v1/models → ["deepseek-v4-flash", "deepseek-v4-flash-dspark", "vllm/deepseek-v4-flash"]
```

Holmes config sets `MODEL=openai/deepseek-v4-flash` — the `openai/` prefix is
**critical** because litellm (Holmes uses litellm under the hood) needs to
know which provider adapter to use. Without it, litellm errors:
```
LLM Provider NOT provided. Pass in the LLM provider you are trying to call.
You passed model=deepseek-v4-flash
```

---

## Reference: dev/build/test commands

```bash
# Render-test all clusters (uses flate against clusters/<c>/flux/config)
make test
make test-talos-ottawa
make test-talos-robbinsdale
make test-talos-stpetersburg

# Live kubectl (kubeconfig in repo)
export KUBECONFIG=/Users/rajsingh/Documents/GitHub/kubernetes-manifests/.kube/config
kubectl --context ottawa get pods -n ai-sre
kubectl --context stpetersburg get pods -n ai-sre
kubectl --context robbinsdale get pods -n ai-sre

# Flux reconcile
flux --context ottawa reconcile helmrelease holmes -n ai-sre
flux --context ottawa reconcile source git kubernetes-manifests
flux --context ottawa reconcile kustomization kubernetes-apps -n flux-system

# SOPS
SOPS_PGP_FP=FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5
sops --encrypt --pgp $SOPS_PGP_FP --encrypted-regex '^(data|stringData)$' plain.yaml > secret.sops.yaml
sops --decrypt secret.sops.yaml

# HolmesGPT repo (cloned for reference)
cd /Users/rajsingh/Documents/GitHub/holmesgpt
# AG-UI server source:
less experimental/ag-ui/server-agui.py
# Helm chart:
less helm/holmes/templates/holmes.yaml

# Headlamp plugin source
cd /Users/rajsingh/Documents/GitHub/headlamp-plugins
less ai-assistant/src/agent/holmesClient.ts
```

---

## Reference: commit history (this session)

```
f6f4e4499 fix(ai-sre): use inline JSON6902 patch for holmes AG-UI command + probes
8658f1e32 simplify(ai-sre): strip netpols, fix holmes model + AG-UI server, wire headlamp
e441a4bd7 feat(ai-sre): expose holmes-shim MCP via direct Tailscale LoadBalancer   (prior)
```

Both are on `origin/main`. The second commit (`f6f4e4499`) fixed the
strategic-merge-can't-replace-probe-handler problem that the kustomize patch
hit — switched to inline JSON6902 patch syntax directly in `kustomization.yaml`.
But §1 above explains why even that isn't enough for the HelmRelease path.
