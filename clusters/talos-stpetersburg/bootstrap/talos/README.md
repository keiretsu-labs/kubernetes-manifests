# Talos Configuration for St. Petersburg Cluster

This directory contains the Talos Linux configuration for the St. Petersburg cluster.

## Nodes

| Hostname | Model | Control Plane | Disk | MAC Address | Schematic |
|----------|-------|---------------|------|-------------|-----------|
| **spark-0** | NVIDIA GB10 Grace Hopper | yes | Samsung NVMe (S8C2NG0Y733052) | `4c:bb:47:2d:95:33` | NVIDIA-flavored (fa4bd976...) |
| **spark-1** | NVIDIA GB10 Grace Hopper | yes | Samsung NVMe (S8C2NG0Y806827) | `4c:bb:47:2b:90:4c` | NVIDIA-flavored (fa4bd976...) |
| **orin-0** | NVIDIA Jetson Orin | yes | onboard M.2 NVMe | `3c:6d:66:76:77:55` | Minimal arm64 (4c073ebf...) |

All three nodes share a **VIP: 192.168.73.25**.

## Prerequisites

Install required tools using mise:
```bash
cd clusters/talos-stpetersburg
mise install
```

## Initial Setup

### 1. Generate Secrets
```bash
mise run init
```
Creates and encrypts `talsecret.sops.yaml` using PGP key.

### 2. Generate Configuration
```bash
mise run genconfig
```
Generates node configs in `clusterconfig/`.

### 3. Download ISOs

Two separate schematics — spark nodes use the NVIDIA-flavored arm64 image (GB10 GPU), orin-0 uses a minimal arm64 image (Tegra GPU unused):

```bash
# NVIDIA GB10 nodes
mise run iso-spark

# Jetson Orin node
mise run iso-orin
```

### 4. Flash USB and Boot

Flash each ISO to a USB drive and boot the corresponding node.

### 5. Apply Configuration

Once a node is in maintenance mode:
```bash
mise run apply-insecure
```

For orin-0 specifically (supply its IP):
```bash
mise run apply-orin-insecure <orin-0-ip>
```

### 6. Bootstrap Cluster
```bash
mise run bootstrap
```

### 7. Fetch Kubeconfig
```bash
mise run kubeconfig
```

## Post-Bootstrap (GitOps)

After bootstrapping, all workload management is handled via **Flux CD** from the `clusters/talos-stpetersburg/apps/` directory. Do not apply resources manually — commit changes to the repository and let Flux reconcile.

## NVIDIA GPU Configuration (spark-0 / spark-1)

The spark nodes include:
- `siderolabs/nonfree-kmod-nvidia-lts` — Proprietary NVIDIA GPU drivers (nonfree)
- `siderolabs/nvidia-container-toolkit-lts` — Container runtime GPU support

GPU Operator (deployed via Flux from `clusters/common/apps/gpu-operator`):
- `driver.enabled=false` — Talos handles the kernel module
- `toolkit.enabled=true`

## Common Tasks

```bash
# Check cluster health
mise run health

# View Talos dashboard
mise run dashboard

# Check GPU status (spark nodes)
mise run gpu-status

# View kernel logs
mise run dmesg

# Open shell on node
mise run talos-shell [node]

# Show cluster nodes
mise run nodes
```

## Network Configuration

- **Pod CIDR:** 10.5.0.0/16
- **Service CIDR:** 10.4.0.0/16
- **LAN:** 192.168.73.0/24
- **VIP:** 192.168.73.25
- **CNI:** None (Cilium installed separately via Flux)

## Troubleshooting

### GPU Not Detected (spark nodes)
```bash
talosctl -n spark-0 read /proc/modules | grep nvidia
mise run dmesg | grep -i nvidia
```

### Network Issues
```bash
mise run link
mise run addresses
```
