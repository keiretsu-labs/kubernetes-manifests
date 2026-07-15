# kubernetes-manifests — agent guide

Production GitOps repo managing three Kubernetes clusters — Ottawa (primary:
media, databases, Rook-Ceph), Robbinsdale (home automation, Rook-Ceph), and
St. Petersburg (AI/ML: GPUs, KServe, Ray) — via Flux CD, with deep Tailscale
integration for cross-cluster networking and access.

## Ground rules

- **GitOps-first.** Never `helm install` / `kubectl apply` manifests directly;
  changes go through Git and Flux. (`kubectl patch` is OK for live testing —
  `kubectl apply` can't resolve Flux `${VARIABLE}` substitutions.)
- **Verify with `tools/check.sh`** (or `tools/check.sh <cluster>`) — runs the
  CI render gate (`make test`), silent on success, ~50 lines on failure. Do
  NOT run raw `make test` or `kustomize build`; they dump thousands of lines.
- **Find before you read.** Use `tools/where.sh <pattern> <file>` (grep -n)
  to locate sections, then read narrow windows. Don't re-read large files.
  To locate an app (base dir + which clusters deploy it) in one call, use
  `tools/app.sh <name>` instead of a manual find + cross-tree grep.
- **Secrets are SOPS-encrypted** (`*.sops.yaml`, PGP key
  FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5). Never commit plaintext secrets,
  kubeconfigs, `talsecret.yaml`, or decrypted `*.dec` files.
- **Commit as the local user only** (rajsinghtech / rajsinghcpre@gmail.com).
  No AI signatures, co-author trailers, or generated-with lines.
- You have local network access to pod/service/LB CIDRs over Tailscale —
  curl services directly, no port-forwarding needed.

## Layout

```
kubernetes/apps/
├── base/<ns>/<app>/         # real manifests, exactly once
│                            # (split <app>-<location>/ when config differs)
├── ottawa/<ns>/             # per-location overlays = thin pointer files
├── robbinsdale/<ns>/
└── stpetersburg/<ns>/
    ├── kustomization.yaml   # lists pointer files (+ namespace.yaml if owned)
    └── <app>.yaml           # Flux Kustomization CR, spec.path → base
clusters/                    # bootstrap + shared config ONLY (no workloads)
├── common/flux/repositories # Helm/OCI/Git sources
├── common/flux/vars         # common-settings / common-secrets (SOPS)
└── talos-<location>/        # per-cluster flux config + Talos bootstrap
tailscale/                   # policy.hujson (ACLs) + automation scripts
tools/                       # agent helper scripts (check.sh, where.sh, ...)
```

Reconcile chain: `clusters/talos-<location>/flux/config/cluster.yaml` defines
the `kubernetes-apps` Kustomization → `./kubernetes/apps/<location>`, which
injects SOPS decryption and the `substituteFrom` stack (common-settings/
common-secrets + cluster-settings/cluster-secrets) into every pointer.

**Deploy-to-some-clusters** = the pointer file exists only in those location
trees. An app in `base/` with no pointer anywhere is not deployed.

## Adding a new app

**Copy the worked example in `docs/reference/app-template.md`** — complete
base manifests, the pointer Kustomization, and a tailnet HTTPRoute with the
per-cluster `${CLUSTER_DOMAIN}` values already filled in. Reading it once beats
grepping the tree for the pointer shape, the `substituteFrom` stack, the domain
values, and an HTTPRoute example. The checklist below is the summary.

1. New Helm chart source? Add a HelmRepository under
   `clusters/common/flux/repositories/helm/<name>.yaml` and list it in that
   dir's `kustomization.yaml`.
2. Create `kubernetes/apps/base/<ns>/<app>/`:
   - `helmrelease.yaml` (or raw manifests)
   - `httproute.yaml` if exposing via Gateway API
   - `kustomization.yaml` — sets namespace, lists resources
   - `namespace.yaml` only if this app owns the namespace (keep
     `kustomize.toolkit.fluxcd.io/prune: disabled`)
3. Per target location, add the pointer
   `kubernetes/apps/<location>/<ns>/<app>.yaml` — a
   `kustomize.toolkit.fluxcd.io/v1` Kustomization with
   `spec.path: ./kubernetes/apps/base/<ns>/<app>[-<location>]`,
   `sourceRef.name: kubernetes-manifests`, plus any `dependsOn` /
   `postBuild.substitute`. The CR `metadata.name` is the app's identity.
4. List the pointer (and `namespace.yaml` if owned) in
   `kubernetes/apps/<location>/<ns>/kustomization.yaml`.
5. Verify with `tools/check.sh` before committing.

### Variable substitution

Every pointer inherits:

```yaml
postBuild:
  substituteFrom:
    - { kind: ConfigMap, name: common-settings }
    - { kind: Secret,    name: common-secrets }
    - { kind: ConfigMap, name: cluster-settings, optional: true }
    - { kind: Secret,    name: cluster-secrets,  optional: true }
```

## Critical gotchas

- **`$` mangling:** Flux envsubst (drone/envsubst) eats bare `$` (bcrypt
  hashes, regex, shell). Any value containing `$` must live in a
  Secret/ConfigMap and be injected via `${VAR}`. Substitution is single-pass:
  `$` inside a replacement value is NOT re-processed. In raw manifests that
  Flux renders, write `$${...}` to emit a literal `${...}`.
- **Gateway hostnames:** check listener hostnames before adding an HTTPRoute:
  `kubectl get gateway <name> -n home -o jsonpath='{.spec.listeners[*].hostname}'`.
  Common gateways (`ts`, `private`, `public`) live in namespace `home` and
  accept `*.${CLUSTER_DOMAIN}` (e.g. `*.killinit.cc` for Ottawa); `public`
  (and now `private`) also accept `*.${COMMON_DOMAIN}` (`*.keiretsu.top`).
  `NoMatchingListenerHostname` in HTTPRoute status = no listener matches.
- **DNS:** `${CLUSTER_DOMAIN}` hostnames get DNS automatically (external-dns
  watches HTTPRoutes). `${COMMON_DOMAIN}` hostnames do NOT — you MUST add a
  CNAME entry in `kubernetes/apps/base/k8gb/k8gb-common/config/cnames.yaml`
  (Ottawa-only: target `"ottawa.${COMMON_DOMAIN}"`; multi-cluster/k8gb:
  `"<name>.cdn.${COMMON_DOMAIN}"`; both `cloudflare-proxied: "false"`).
  Without it the route shows Accepted=True but never resolves.
- **Tailnet DNS from pods:** do not publish Tailscale CGNAT (`100.64.0.0/10`)
  in public DNS and do not assume a new `*.keiretsu.ts.net` device name is
  automatically present in pod DNS. For every tailnet target, define an
  `ExternalName` Service annotated with `tailscale.com/tailnet-fqdn` and
  `tailscale.com/proxy-group: common-egress`. The Tailscale `DNSConfig`
  nameserver then publishes that original `.ts.net` name as the egress proxy's
  cluster IP. Verify the Service condition `TailscaleEgressSvcReady=True` and
  resolve the `.ts.net` name from a pod before configuring clients. See
  `docs/reference/tailscale-integration.md`.
- **SOPS:** run `sops` from the directory whose `.sops.yaml` carries the
  creation rules. Edit with `sops <file>.sops.yaml`.

## Live cluster access

- kubeconfig: `.kube/config` in the repo root (all three clusters); also
  `/workspace/kubernetes-manifests/.kube/config` in container environments.
- kubectl contexts: `ottawa-k8s-operator.keiretsu.ts.net`,
  `robbinsdale-k8s-operator.keiretsu.ts.net`; St. Petersburg via
  `--kubeconfig ~/.kube/stpetersburg`.
- Pod/service CIDRs per site: Robbinsdale 10.1/10.0/10.50, Ottawa
  10.3/10.2/10.169, St. Petersburg 10.5/10.4/10.73 (pods/services/LB, /16s).

## Commands

```bash
tools/check.sh [cluster]   # CI render gate — the sole verify command
make diff                  # rendered diff vs origin/main
flux get all -A            # Flux status (live cluster)
flux reconcile kustomization <app> -n flux-system
```

## Deeper reference

- `kubernetes/README.md` — authoritative layout description
- `docs/reference/talos.md` — Talos/talhelper bootstrap structure
- `docs/reference/tailscale-integration.md` — operator resources, ACL policy,
  scripts, CI workflows
- `docs/reference/tsdb.md` — historical tsdb connector notes
- `docs/prompt-notes.md` — prompt patterns that worked/failed for build agents
