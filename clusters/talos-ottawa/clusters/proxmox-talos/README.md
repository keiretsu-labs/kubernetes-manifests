# Proxmox + Talos + Cluster API (ottawa-proxmox)

This directory defines the GitOps-managed CAPI/Talos workload cluster on Proxmox. It also documents the manual host-side steps we performed and the bootstrap issues we fixed.

## Scope

- Cluster manifests (CAPI + CAPMox + Talos) for the `ottawa-proxmox` workload cluster.
- Cilium CNI installed via Cluster API Addon Provider (HelmChartProxy).
- Optional Flux bootstrap via ClusterResourceSet (CRS) as a reference implementation.
- Operational notes for Proxmox template preparation and cluster recreation.

## Key Files

- `cluster.yaml`: Cluster + ProxmoxCluster objects, labels, and networking.
- `control-plane.yaml`: TalosControlPlane, control-plane machine template, and Talos strategic patches.
- `workers.yaml`: MachineDeployment, worker template, and TalosConfigTemplate.
- `cilium-helmchartproxy.yaml`: HelmChartProxy for Cilium (addon-provider-helm).
- `flux-bootstrap/`: Example ClusterResourceSet to bootstrap Flux without Helm.

## Management Cluster

- This repo is reconciled by Flux on the management cluster (`~/.kube/ottawa`).
- Workload cluster kubeconfig is stored as a Secret in the management cluster:
  - `kubectl --kubeconfig ~/.kube/ottawa -n default get secret ottawa-proxmox-kubeconfig -o jsonpath='{.data.value}' | base64 --decode > /tmp/ottawa-proxmox.kubeconfig`

## Proxmox Template (Manual, Host-Side)

These steps are outside GitOps and must be done directly on the Proxmox host.

1) Use the **Talos NoCloud image** (not the metal image). Cloud-init only works with NoCloud.
2) Create a Proxmox VM template with **cloud-init disk** and **virtio VGA** so console works.
3) Template ID is referenced via `CAPI_PROXMOX_TEMPLATE_ID` (currently `9000`).
4) Clean up old/incorrect images to avoid confusion.

Notes:
- This template is used by CAPMox to clone VMs for control-plane and workers.
- The NoCloud image is required for deterministic IPs and cloud-init support.

## Talos Configuration (Strategic Patches)

Control-plane patching (see `control-plane.yaml`):
- Installs Talos to `${CAPI_TALOS_INSTALL_DISK}` and adds qemu-guest-agent extension.
- Adds `net.ifnames=0` for predictable `eth0` naming.
- Configures control-plane VIP.
- Enables external cloud provider and installs:
  - Talos cloud-controller-manager
  - kubelet-serving-cert-approver
- Enables kubelet server certificate rotation.
- Disables built-in CNI (`cluster.network.cni: none`) so Cilium provides CNI.
- Allows scheduling on control-plane nodes.
- Removes `node.kubernetes.io/exclude-from-external-load-balancers` from control-plane nodes.
- Enables Talos API access for control-plane only.

Worker patching (see `workers.yaml`):
- Sets external cloud provider and rotates kubelet serving certs.
- Disables built-in CNI (`cluster.network.cni: none`).
- Talos API access is not enabled for workers.

## Cilium (Bootstrap-Safe)

Cilium is installed via CAAPH (Cluster API Addon Provider - Helm) using `HelmChartProxy`.

Key settings in `cilium-helmchartproxy.yaml`:
- `install.includeCRDs: true` so CRDs are installed by Helm.
- Tolerations to avoid bootstrap deadlocks:
  - `node.cloudprovider.kubernetes.io/uninitialized` (Cilium and operator)
  - `node.kubernetes.io/not-ready`
  - `node.kubernetes.io/unreachable`
  - `node-role.kubernetes.io/control-plane` / `master`
  - `node.cilium.io/agent-not-ready` (Cilium agent tolerates its own taint)
- `kubeProxyReplacement: false` (default kube-proxy)
- `ipam.mode: kubernetes`
- `cgroup.autoMount.enabled: false` with `hostRoot: /sys/fs/cgroup`

### Why these tolerations matter

Bootstrap deadlock we hit:
1) Nodes tainted `node.cloudprovider.kubernetes.io/uninitialized`.
2) Cilium operator couldn’t schedule (no toleration) -> no CRDs.
3) Cilium agents couldn’t fully initialize -> CNI not ready.
4) `kubelet-serving-cert-approver` couldn’t schedule -> kubelet-serving CSRs pending.

Fix: allow Cilium + operator to schedule despite taints so the approver can run and auto-approve CSRs.

## CAAPH (Addon Provider - Helm)

Cilium installation relies on CAAPH (Cluster API Addon Provider Helm).

- CAAPH version is pinned to `v0.4.2` in `clusters/talos-ottawa/apps/caaph-system/app/provider.yaml`.
- We downgraded because v0.5.3 expects CAPI v1beta2 CRDs that are not present.
  - Operator logs showed: `no matches for kind "Cluster" in version "cluster.x-k8s.io/v1beta2"`.
- Downgrades require deleting the AddonProvider CR first (the operator does not support in-place downgrades).

## Cluster Recreation Procedure (No Manual CSR Approval)

This procedure validates that bootstrap works end-to-end without manual CSR approvals.

1) Suspend CAPI cluster kustomization:
   - `kubectl --kubeconfig ~/.kube/ottawa -n flux-system patch kustomization capi-clusters --type=merge -p '{"spec":{"suspend":true}}'`
2) Delete the Cluster:
   - `kubectl --kubeconfig ~/.kube/ottawa -n default delete cluster.cluster.x-k8s.io ottawa-proxmox`
3) Wait for deletion to complete.
4) Resume kustomization:
   - `kubectl --kubeconfig ~/.kube/ottawa -n flux-system patch kustomization capi-clusters --type=merge -p '{"spec":{"suspend":false}}'`
5) Watch:
   - Cilium pods should come up and become Ready.
   - `kubelet-serving-cert-approver` should schedule and auto-approve kubelet-serving CSRs.
   - Nodes transition to Ready without manual CSR approval.

## Commands: Instantiate vs Delete Cluster

These are the day-to-day commands to create or tear down the workload cluster using Flux + CAPI.

### Instantiate (Create) the Cluster

If the `capi-clusters` Kustomization is already active, Flux will create the cluster automatically from Git. You can force a reconcile like this:

```
kubectl --kubeconfig ~/.kube/ottawa -n flux-system annotate gitrepository kubernetes-manifests reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
kubectl --kubeconfig ~/.kube/ottawa -n flux-system annotate kustomization capi-clusters reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
```

If it was previously suspended:

```
kubectl --kubeconfig ~/.kube/ottawa -n flux-system patch kustomization capi-clusters --type=merge -p '{"spec":{"suspend":false}}'
```

## Commands: Grab ConfigMaps

### Management Cluster (Flux/CAPI settings)

List cluster settings ConfigMaps in `flux-system`:

```
kubectl --kubeconfig ~/.kube/ottawa -n flux-system get configmaps
```

Show the user settings used by this cluster:

```
kubectl --kubeconfig ~/.kube/ottawa -n flux-system get configmap cluster-user-settings -o yaml
```

### Workload Cluster (ottawa-proxmox)

First, get kubeconfig for the workload cluster:

```
kubectl --kubeconfig ~/.kube/ottawa -n default get secret ottawa-proxmox-kubeconfig -o jsonpath='{.data.value}' | base64 --decode > /tmp/ottawa-proxmox.kubeconfig
```

List all ConfigMaps in the workload cluster:

```
kubectl --kubeconfig /tmp/ottawa-proxmox.kubeconfig get configmaps -A
```

Show Cilium config (example):

```
kubectl --kubeconfig /tmp/ottawa-proxmox.kubeconfig -n kube-system get configmap cilium-config -o yaml
```

### Delete the Cluster (Tear Down)

Suspend GitOps first to avoid it being recreated immediately:

```
kubectl --kubeconfig ~/.kube/ottawa -n flux-system patch kustomization capi-clusters --type=merge -p '{"spec":{"suspend":true}}'
```

Delete the Cluster object (this cascades to infra resources):

```
kubectl --kubeconfig ~/.kube/ottawa -n default delete cluster.cluster.x-k8s.io ottawa-proxmox
```

Wait for deletion to complete:

```
kubectl --kubeconfig ~/.kube/ottawa -n default wait --for=delete cluster.cluster.x-k8s.io/ottawa-proxmox --timeout=15m
```

Resume GitOps when you’re ready to recreate:

```
kubectl --kubeconfig ~/.kube/ottawa -n flux-system patch kustomization capi-clusters --type=merge -p '{"spec":{"suspend":false}}'
```

## Flux Bootstrap via ClusterResourceSet (Example)

We added an example CRS to show how Cluster API can bootstrap Flux without Helm.

Path: `flux-bootstrap/`

How it works:
- `flux-bootstrap/flux-install.yaml` is a **pre-rendered** output of:
  - `clusters/common/bootstrap/flux/kustomization.yaml`
- `flux-bootstrap/kustomization.yaml` creates a ConfigMap with that YAML.
- `flux-bootstrap/clusterresourceset.yaml` applies it to clusters matching:
  - `bootstrap.flux: "true"`

This is **inactive by default** (no label applied). If you want it enabled:
1) Add `bootstrap.flux: "true"` to `cluster.yaml` labels.
2) Reconcile; CRS will install Flux into the workload cluster.

Important: CRS does **not** run Kustomize. You must pre-render the YAML (as done here).

## Known Good State (After Fixes)

- All nodes Ready without manual CSR approvals.
- Cilium DS Ready on all nodes.
- kubelet-serving-cert-approver Running and auto-approving CSRs.
- Control-plane node schedulable for workloads and eligible for LB targets.

## Security Notes

- All secrets should be SOPS-encrypted in Git.
- Proxmox API tokens and passwords should never be committed.
- Flux bootstrap example includes the rendered install YAML; ensure any sensitive data stays in SOPS-encrypted Secrets.

## References

- Talos + CAPMox guide (used as baseline):
  - https://a-cup-of.coffee/blog/talos-capi-proxmox/
- CAPMox usage and Cilium template:
  - https://github.com/ionos-cloud/cluster-api-provider-proxmox/blob/main/docs/Usage.md
  - https://github.com/ionos-cloud/cluster-api-provider-proxmox/blob/main/templates/cluster-template-cilium.yaml
- Talos Cilium guide:
  - https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
- Talos workers on control plane:
  - https://docs.siderolabs.com/talos/v1.7/deploy-and-manage-workloads/workers-on-controlplane
