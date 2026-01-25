# Talos Configuration for DGX Spark (St. Petersburg)

This directory contains the Talos Linux configuration for the NVIDIA DGX Spark cluster.

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
This creates and encrypts `talsecret.sops.yaml` using PGP key.

### 2. Generate Configuration
```bash
mise run genconfig
```
This generates node configs in `clusterconfig/`.

### 3. Download ISO
```bash
mise run iso
```
This downloads a custom Talos ISO with NVIDIA extensions.

### 4. Flash USB and Boot
Flash the ISO to a USB drive and boot the DGX Spark from it.

### 5. Apply Configuration
Once the node is in maintenance mode:
```bash
mise run apply-insecure
```

### 6. Bootstrap Cluster
```bash
mise run bootstrap
```

### 7. Fetch Kubeconfig
```bash
mise run kubeconfig
```

## NVIDIA GPU Configuration

The cluster is configured with:
- `siderolabs/nvidia-open-gpu-kernel-modules` - Open-source NVIDIA GPU drivers
- `siderolabs/nvidia-container-toolkit` - Container runtime GPU support

After bootstrapping, install the NVIDIA GPU Operator:
```bash
# GPU operator will be deployed via Flux from clusters/common/apps/gpu-operator
# or you can manually install:
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled=true
```

## Common Tasks

```bash
# Check cluster health
mise run health

# View Talos dashboard
mise run dashboard

# Check GPU status
mise run gpu-status

# View kernel logs (check NVIDIA loading)
mise run dmesg

# Open shell on node
mise run talos-shell
```

## Network Configuration

- **Pod CIDR:** 10.5.0.0/16
- **Service CIDR:** 10.4.0.0/16
- **LAN:** 192.168.73.0/24
- **VIP:** 192.168.73.25

## Troubleshooting

### GPU Not Detected
Check if NVIDIA modules are loaded:
```bash
talosctl -n spark-0 read /proc/modules | grep nvidia
```

Check kernel logs for NVIDIA errors:
```bash
mise run dmesg | grep -i nvidia
```

### Network Issues
```bash
mise run link      # Show network links
mise run addresses # Show IP addresses
```
