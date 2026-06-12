# Talos Kubernetes Cluster (Ottawa)

3 control planes + 1 worker running Talos Linux, managed via `mise` and `talhelper`.

| Node   | Role         | IP              | Boot Disk Serial    |
|--------|-------------|-----------------|---------------------|
| asuka  | controlplane | 192.168.169.117 | 50026B7686F79D0F    |
| rei    | controlplane | 192.168.169.118 | 50026B7686F78587    |
| kaji   | controlplane | 192.168.169.119 | 50026B7686F78574    |
| shiro  | worker       | 192.168.169.116 | 2316E6CC4FC6        |

**VIP:** 192.168.169.25 (shared across control planes on bond0)
**Domain:** `killinit.internal`
**Cluster endpoint:** `https://k8s.killinit.internal:6443`

## Prerequisites

```bash
brew install mise gpg
mise install  # talhelper, talosctl, sops, kubectl, task
```

Import PGP key (`FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5`) and trust it:

```bash
gpg --import /path/to/sops.asc
echo "FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5:6:" | gpg --import-ownertrust
sops -d --ignore-mac ../../flux/vars/cluster-secrets.sops.yaml > /dev/null && echo "OK"
```

## Fresh Installation Workflow

### 1. Generate and Encrypt Secrets

```bash
# From clusters/talos-ottawa/
mise run init
```

Creates `bootstrap/talos/talsecret.sops.yaml` (PGP-encrypted).

### 2. Build Installation Media

```bash
mise run iso              # Download schematic ISO from factory.talos.dev
# Write to USB (macOS)
diskutil list
sudo dd if=metal-amd64.iso of=/dev/rdiskX bs=1m status=progress
```

### 3. Boot Nodes into Maintenance Mode

- Boot all 4 nodes from USB (run entirely in RAM until config is applied)
- Static DHCP must assign expected IPs to each node
- Verify reachability:

```bash
for ip in 192.168.169.117 192.168.169.118 192.168.169.119 192.168.169.116; do
  talosctl -n $ip -e $ip version --insecure | grep Tag || echo "Not responding"
done
```

### 4. Gather Disk Info (optional, for new hardware)

```bash
for node in rei asuka kaji shiro; do
  talosctl -n $node -e $node get disks --insecure -o yaml
done
```

Update serial numbers in `talconfig.yaml` to match actual hardware.

### 5. Generate and Deploy Configurations

```bash
mise run genconfig                  # generates clusterconfig/*.yaml
../../scripts/verify-disks.sh       # verify disk selections match hardware
mise run apply-insecure             # apply to nodes in maintenance mode
# Wait for nodes to reboot (~90s)
mise run bootstrap                  # bootstrap etcd on first node
mise run kubeconfig                 # fetch kubeconfig
kubectl get nodes                   # verify cluster is up
```

### 6. Cilium (deployed via Flux, NOT helm)

Cilium is managed at `../../base/kube-system/cilium-ottawa/`. Flux installs it automatically once `cilium-helmrelease` is committed.

### 7. Flux Bootstrap

Flux is bootstrapped from `../../../common/bootstrap/flux/`. No manual `kubectl apply --kustomize` needed.

## `mise run` Tasks

| Command | Description |
|---|---|
| `mise run init` | Generate and encrypt Talos secrets |
| `mise run genconfig` | Generate node configs from talconfig |
| `mise run apply` | Apply configs to running cluster |
| `mise run apply-insecure` | Apply configs in maintenance mode (initial install) |
| `mise run apply-staged` | Stage configs for next reboot |
| `mise run bootstrap` | Bootstrap etcd |
| `mise run kubeconfig` | Fetch kubeconfig |
| `mise run health` | Check cluster health |
| `mise run dashboard` | Open Talos dashboard |
| `mise run reset` | Reset cluster + wipe Ceph drives (DESTRUCTIVE) |
| `mise run reset-node <name>` | Reset single node to maintenance mode |
| `mise run upgrade [version]` | Upgrade Talos on all nodes |
| `mise run iso` | Download custom Talos ISO |
| `mise run reboot` | Reboot all nodes sequentially |
| `mise run disk` | Show discovered volumes |
| `mise run link` | Show network link status |
| `mise run addresses` | Show IP addresses |
| `mise run service` | List services per node |
| `mise run logs <service> <node>` | Show service logs |
| `mise run dmesg <node>` | Show kernel logs |
| `mise run talos-shell <node>` | Open interactive shell on node |
| `mise run etcd` | Check etcd service status |
| `mise run static` | List static pods |
| `mise run nodes` | `kubectl get nodes` |
| `mise run pods` | `kubectl get pods -A` |
| `mise run k9s` | Launch k9s dashboard |

## Environment

```bash
export TALOSCONFIG=$(pwd)/bootstrap/talos/clusterconfig/talosconfig
export KUBECONFIG=$(pwd)/kubeconfig
# Also set automatically by mise via .mise.toml [env] section
```

## Directory Structure

```
clusters/talos-ottawa/
├── .mise.toml              # Mise config: tools, tasks, env vars
├── bootstrap/talos/
│   ├── talconfig.yaml      # Node definitions, patches, schematic
│   ├── talsecret.sops.yaml # PGP-encrypted cluster secrets
│   ├── Taskfile.yaml       # Task runner (called by mise)
│   ├── clusterconfig/      # Generated per-node configs (git-ignored)
│   └── patches/            # Global, controller, and node patches
├── scripts/
│   └── verify-disks.sh     # Verify disk config vs hardware
├── flux/                   # GitOps config
│   └── vars/
│       └── cluster-secrets.sops.yaml
└── apps/                   # Application manifests (Flux-managed)
```

## GitOps Philosophy

All cluster state is Git-managed. Never `kubectl apply` or `helm install` manually for persistent resources. Commit changes, let Flux reconcile. Talos node configs (`talconfig.yaml`) and patches are the exception — they bootstrap the cluster before Flux can run.