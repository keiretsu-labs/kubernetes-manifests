# Talos Kubernetes Cluster (Ottawa)

This setup uses `mise` and `talhelper` to manage the Ottawa Talos Kubernetes cluster (3 control planes + 1 Intel worker).

## Table of Contents

- [Prerequisites](#prerequisites)
- [Complete Fresh Installation Workflow](#complete-fresh-installation-workflow)
- [Post-Installation](#post-installation)
- [Common Operations](#common-operations)
- [Troubleshooting](#troubleshooting)
- [Directory Structure](#directory-structure)

## Prerequisites

### Hardware Requirements

- Bare-metal nodes with:
  - Multiple NVMe drives (using `/dev/nvme1n1` for Talos)
  - Network interfaces configured with static DHCP mappings

### Expected Network Configuration

- **rei**: 192.168.169.117 (Static DHCP on eth1)
- **asuka**: 192.168.169.118 (Static DHCP on eth1)
- **kaji**: 192.168.169.119 (Static DHCP on eth1)
- **shiro** (worker): 192.168.169.116
- **VIP**: 192.168.169.25 (shared between control planes)

## Complete Fresh Installation Workflow

### Phase 1: Workstation Preparation

```bash
# 1. Navigate to cluster directory
cd clusters/talos-ottawa

# 2. Install required tools
brew install mise gpg
mise install  # Installs: talhelper, talosctl, sops, kubectl, task

# 3. Setup SOPS with existing PGP key
# Copy existing SOPS configuration (we're using PGP, not Age)
cp ../common/.sops.yaml .

# Import your PGP private key (if you have a sops.asc file)
# IMPORTANT: Replace /path/to/sops.asc with your actual key location
gpg --import /path/to/sops.asc

# Verify the key was imported
gpg --list-secret-keys | grep -B2 FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5

# Trust the key (required for encryption)
echo "FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5:6:" | gpg --import-ownertrust

# Set GPG_TTY for terminal PIN entry (if needed)
export GPG_TTY=$(tty)

# Test that you can decrypt existing secrets
sops -d --ignore-mac flux/vars/cluster-secrets.sops.yaml > /dev/null && echo "✅ PGP key working" || echo "❌ Cannot decrypt - check PGP key"

# 4. Generate and encrypt Talos cluster secrets
# IMPORTANT: This MUST be run for fresh cluster installs!
# Even though you're using the same PGP key, you need NEW Talos secrets 
# (cluster CA, etcd certs, node tokens) for the fresh installation.
mise run init

# This command will:
# - Generate NEW Talos secrets (required for fresh install)
# - Automatically encrypt them with your EXISTING PGP key (FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5)
# - Save to bootstrap/talos/talsecret.sops.yaml
# - Remove unencrypted temporary files

# Verify encryption worked
sops -d bootstrap/talos/talsecret.sops.yaml | head -5  # Should show decrypted content
```

### Phase 2: Create Installation Media

```bash
# 1. Download Talos ISO with required extensions
# This schematic includes: intel-ucode, amd-ucode, util-linux-tools, zfs
SCHEMATIC_ID="d07283f5e88e9fedac14ee45b711b7d4f6e036363f1c31bb61b5194a0ff0519f"
TALOS_VERSION="v1.10.6"
curl -O "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.iso"

# 2. Create bootable USB (macOS)
diskutil list                          # Find your USB drive (e.g., disk4)
diskutil unmountDisk /dev/diskX        # Replace X with your disk number
sudo dd if=metal-amd64.iso of=/dev/rdiskX bs=1m status=progress
diskutil eject /dev/diskX

# Note: Use 'rdiskX' (raw disk) for faster writes on macOS
```

### Phase 3: Physical Setup & Installation

1. **Pre-Installation Checklist:**
   - [ ] Connect network cables
   - [ ] Ensure static DHCP mappings are configured for:
     - rei: 192.168.169.117
     - asuka: 192.168.169.118
     - kaji: 192.168.169.119
   - [ ] Have IPMI/console access ready

2. **Boot all 3 nodes from USB:**
   - Boot each node from the Talos USB
   - Nodes will run entirely in RAM (no disk changes yet)
   - Note the IP addresses shown on console
   - Verify you can reach each node:
     ```bash
     # Check if node is accessible
     talosctl -n <node-ip> -e <node-ip> version --insecure
     ```
   - If DHCP reservation was added after boot, force renewal:
     ```bash
     talosctl -n <old-ip> --insecure reboot  # Simplest way
     ```
   - Verify each node gets its expected IP via static DHCP

3. **Verify all nodes are in maintenance mode:**
```bash
# Should see all 3 nodes responding
for ip in 192.168.169.117 192.168.169.118 192.168.169.119; do
  echo -n "Node $ip: "
  talosctl -n $ip -e $ip version --insecure | grep Tag || echo "❌ Not responding"
done
```

### Phase 4: Gather Hardware Information

**Critical: Do this for ALL nodes before generating configs**

```bash
# WORKING DIRECTORY: clusters/talos-ottawa
cd clusters/talos-ottawa

# Create directory for hardware info
mkdir -p hardware-info

# Gather info from all nodes
echo "📡 Gathering hardware info from all nodes..."

# rei
echo "Getting info from rei..."
talosctl -n 192.168.169.117 -e 192.168.169.117 get disks --insecure -o yaml > hardware-info/rei-disks.yaml
talosctl -n 192.168.169.117 -e 192.168.169.117 get links --insecure -o yaml > hardware-info/rei-links.yaml

# asuka
echo "Getting info from asuka..."
talosctl -n 192.168.169.118 -e 192.168.169.118 get disks --insecure -o yaml > hardware-info/asuka-disks.yaml
talosctl -n 192.168.169.118 -e 192.168.169.118 get links --insecure -o yaml > hardware-info/asuka-links.yaml

# kaji
echo "Getting info from kaji..."
talosctl -n 192.168.169.119 -e 192.168.169.119 get disks --insecure -o yaml > hardware-info/kaji-disks.yaml
talosctl -n 192.168.169.119 -e 192.168.169.119 get links --insecure -o yaml > hardware-info/kaji-links.yaml

# Extract critical information
echo ""
echo "=== 🔍 Disk Information ==="
echo "Looking for SanDisk 1TB NVMe drives to use as system disks..."
echo ""
for node in rei asuka kaji; do
  echo "$node disks:"
  # Show all NVMe drives with model, size, and serial
  for disk in /dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1; do
    if grep -q "dev_path: $disk" hardware-info/${node}-disks.yaml 2>/dev/null; then
      echo "  $disk:"
      grep -A15 "dev_path: $disk" hardware-info/${node}-disks.yaml | grep -E "model:|size:|serial:" | sed 's/^/    /'
    fi
  done
  echo ""
done

echo "=== 📝 Serial Numbers for talconfig.yaml ==="
echo "Copy these serials for your SanDisk 1TB drives:"
for node in rei asuka kaji; do
  echo -n "$node: "
  # Find the SanDisk drive serial (adjust grep pattern if needed)
  grep -B5 -A10 "model:.*SanDisk" hardware-info/${node}-disks.yaml 2>/dev/null | grep "serial:" | head -1 | awk '{print $2}' || echo "No SanDisk found - check manually"
done

echo ""
echo "=== 🔍 Network Interfaces ==="
for node in rei asuka kaji; do
  echo "$node:"
  grep "linkName:" hardware-info/${node}-links.yaml 2>/dev/null | grep -v "lo" | awk '{print "  - " $2}'
done

```

### Phase 5: Update Configuration with Actual Hardware Info

```bash
# 1. Edit talconfig.yaml with the serial numbers you just gathered
vim bootstrap/talos/talconfig.yaml

# For each node, replace REPLACE_WITH_ACTUAL_SERIAL with the actual serial
# Example:
# nodes:
#   - hostname: "rei"
#     installDiskSelector:
#       serial: "S4J4NF0NA12345X"  # <-- Put actual serial here

# 2. Verify network interface names match (should be eth1 and eth2)
# Check with: talosctl -n <node-ip> -e <node-ip> get links --insecure
# If different, update the interface names in talconfig.yaml

# 3. Save and exit
```

### Phase 6: Generate and Deploy Cluster

```bash
# 1. Initialize secrets (if not already done in Phase 1)
mise run init  # Creates and encrypts talsecret.sops.yaml if it doesn't exist

# 2. Generate all node configurations
echo "🔧 Generating Talos configurations..."
mise run genconfig

# 3. Verify generated configs exist
ls -la bootstrap/talos/clusterconfig/
# Should see: k8s.ottawa.local-rei.yaml, k8s.ottawa.local-asuka.yaml, k8s.ottawa.local-kaji.yaml, talosconfig

# 4. Optional: Verify disk configuration in generated files
chmod +x bootstrap/talos/verify-disks.sh
./bootstrap/talos/verify-disks.sh

# 5. Apply configurations to all nodes
echo "📤 Applying configurations to all nodes..."
mise run apply

# This will:
# - Apply k8s.ottawa.local-rei.yaml to 192.168.169.117
# - Apply k8s.ottawa.local-asuka.yaml to 192.168.169.118
# - Apply k8s.ottawa.local-kaji.yaml to 192.168.169.119
# - INSTALLS TALOS TO DISK (as specified in config)
# - Nodes will reboot from disk with their configurations

# 6. Wait for nodes to reboot and settle
echo "⏳ Waiting for nodes to reboot with new configuration..."
sleep 90

# 7. Verify nodes are back online with configs
for node in rei asuka kaji; do
  echo -n "Checking $node: "
  talosctl -n $node -e $node version --short || echo "Still booting..."
done

# 8. Bootstrap the Kubernetes cluster
echo "🚀 Bootstrapping Kubernetes cluster..."
mise run bootstrap

# 9. Get kubeconfig
echo "📥 Fetching kubeconfig..."
mise run kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig

# 10. Verify cluster is up
echo "✅ Checking cluster status..."
kubectl get nodes
```

### Phase 7: Install Cilium CNI

**IMPORTANT**: Cilium must be installed before Flux.

```bash
# 1. Verify cluster is running
kubectl get nodes
# All nodes should show Ready (even though networking isn't fully configured)

# 2. Add Cilium Helm repository
helm repo add cilium https://helm.cilium.io/
helm repo update

# 3. Install Cilium using our custom values
echo "🔧 Installing Cilium CNI..."
helm install cilium cilium/cilium \
  --version 1.16.5 \
  --namespace kube-system \
  --values apps/cilium/app/values.yaml

# 4. Wait for Cilium to be ready
echo "⏳ Waiting for Cilium to initialize..."
cilium status --wait

# Alternative: Check with kubectl
kubectl -n kube-system rollout status daemonset/cilium
kubectl -n kube-system rollout status deployment/cilium-operator

# 5. Verify all nodes are Ready with networking
kubectl get nodes -o wide
```

### Phase 8: Install Flux GitOps

```bash  
# 1. Install Flux GitOps
echo "🔧 Installing Flux GitOps..."

# Create flux-system namespace
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -

# Install Flux CRDs and controllers
kubectl apply --server-side --kustomize flux/config/

# Apply cluster configuration
kubectl apply -f flux/config/cluster.yaml

# Wait for Flux to be ready
echo "⏳ Waiting for Flux controllers..."
kubectl -n flux-system wait deployment --all --for=condition=Available --timeout=300s

# 2. Verify Flux is syncing
echo "🔄 Checking Flux sync status..."
kubectl get kustomizations -n flux-system
kubectl get gitrepositories -n flux-system
kubectl get helmreleases -A

# 3. Wait for nodes to be fully ready
echo "⏳ Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=600s

# 4. Final cluster health check
echo "🏥 Final health check..."
mise run health
kubectl get nodes -o wide
kubectl get pods -A
```

## Post-Installation Verification

### Complete Cluster Check

```bash
# 1. All nodes should be Ready
kubectl get nodes
# Expected: All 3 nodes showing "Ready"

# 2. All system pods should be running
kubectl get pods -n kube-system
kubectl get pods -n flux-system

# 3. Flux should be syncing
flux get sources git
flux get ks -A
```

## Common Operations

### Quick Commands

```bash
# Check cluster status
mise run health

# Open Talos dashboard
mise run dashboard

# View logs from a node
talosctl -n rei logs kubelet

# Update configuration (edit talconfig.yaml first)
mise run genconfig
mise run apply
```

### Upgrade Operations

```bash
# Upgrade Talos on a node
task -d bootstrap/talos upgrade node=rei image=ghcr.io/siderolabs/installer:v1.10.7

# Upgrade Kubernetes
task -d bootstrap/talos upgrade-k8s controller=rei to=v1.33.1
```

## Troubleshooting

### Node Not Responding After Apply

```bash
# Check console/IPMI for errors
# Try applying with insecure flag directly
talosctl -n 192.168.169.117 -e 192.168.169.117 apply-config --insecure --file bootstrap/talos/clusterconfig/k8s.ottawa.local-rei.yaml
```

### Wrong Disk Selected

```bash
# Verify disk serial in config matches actual
grep serial bootstrap/talos/talconfig.yaml
talosctl -n NODE_IP -e NODE_IP get disks --insecure -o yaml | grep -B2 -A3 nvme1n1
```

### Wrong Config File Applied

```bash
# Config files are named: k8s.ottawa.local-NODENAME.yaml
# Example for rei:
talosctl -n 192.168.169.117 -e 192.168.169.117 apply-config --insecure --file bootstrap/talos/clusterconfig/k8s.ottawa.local-rei.yaml
```

### PGP/SOPS Issues - Finding Your Key

```bash
# 1. First, try to decrypt an existing file to see if SOPS can find your key
cd /Users/kartik/workspace/kubernetes-manifests/clusters/talos-ottawa
sops -d flux/vars/cluster-secrets.sops.yaml > /dev/null && echo "✅ Key is working"

# 2. If that works but GPG doesn't show the key, SOPS might be using a different method
# Check how SOPS is currently working:
sops --verbose -d flux/vars/cluster-secrets.sops.yaml 2>&1 | head -20

# 3. Common locations/methods for PGP keys:

# Standard GPG keyring
gpg --list-secret-keys

# GPG with specific home
GNUPGHOME=~/.gnupg gpg --list-secret-keys

# Check for GPG agent
gpg-connect-agent 'keyinfo --list' /bye

# 4. Find any GPG/SOPS related environment variables
env | grep -E "GPG|SOPS|PGP"

# 5. If you find your key in a non-standard location, export it:
gpg --export-secret-keys FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5 > ~/talos-pgp-key.asc

# 6. Then import it to standard location:
gpg --import ~/talos-pgp-key.asc

# 7. Trust the key
echo "FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5:6:" | gpg --import-ownertrust
```

## Directory Structure

```bash
clusters/talos-ottawa/
├── .mise.toml                    # Mise configuration
├── .sops.yaml                    # SOPS/PGP encryption rules
├── bootstrap/talos/
│   ├── talconfig.yaml            # Main configuration (UPDATE THIS)
│   ├── talsecret.sops.yaml       # PGP-encrypted Talos secrets
│   ├── clusterconfig/            # Generated configs (git-ignored)
│   ├── hardware-info/            # Gathered hardware info (reference)
│   └── patches/                  # Configuration patches
│       ├── global/               # Applied to all nodes
│       └── controller/           # Control plane only
├── flux/                         # GitOps configuration
│   └── vars/
│       └── cluster-secrets.sops.yaml  # Existing PGP-encrypted secrets
└── apps/                         # Application manifests
    └── cilium/                   # CNI configuration
```

## Quick Reference Card

### Environment Variables

```bash
export TALOSCONFIG=$(pwd)/bootstrap/talos/clusterconfig/talosconfig
export KUBECONFIG=$(pwd)/kubeconfig
```

### Mise Commands

| Command | Description |
|---------|-------------|
| `mise run genconfig` | Generate configurations |
| `mise run apply` | Apply configs to nodes |
| `mise run bootstrap` | Bootstrap cluster |
| `mise run kubeconfig` | Get kubeconfig |
| `mise run health` | Check health |
| `mise run dashboard` | Open dashboard |
| `mise run reset` | Reset cluster (DESTRUCTIVE) |

### Critical Files to Backup

Before starting fresh install, backup:
- **Your PGP private key** (`sops.asc` file) - CRITICAL! Without this, you cannot decrypt secrets
  ```bash
  # If your key is in GPG, export it:
  gpg --export-secret-keys FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5 > ~/sops-backup.asc
  # Store this file somewhere safe (password manager, secure backup, etc.)
  ```
- Any custom app configurations
- Any important data from PVCs

## Security Notes

### Using PGP Instead of Age

This setup uses your existing PGP key (`FAC8E7C3A2BC7DEE58A01C5928E1AB8AF0CF07A5`) for SOPS encryption:
- ✅ No need to re-encrypt existing secrets
- ✅ Flux secrets work without changes
- ✅ Same encryption method across all clusters

### Files Safe to Commit
- `talconfig.yaml` - Main configuration (no secrets)
- `*.sops.yaml` - PGP-encrypted files
- `patches/**/*.yaml` - Configuration patches

### Files to NEVER Commit (git-ignored)
- `clusterconfig/` - Contains decrypted secrets
- `talsecret.yaml` - Unencrypted Talos secrets
- `hardware-info/` - May contain sensitive system info
- Your PGP private key

## Support

- [Talos Documentation](https://www.talos.dev/latest/)
- [Talhelper Documentation](https://github.com/budimanjojo/talhelper)
- [Mise Documentation](https://mise.jdx.dev/)
- [SOPS Documentation](https://github.com/getsops/sops)