# Talos Patches

This directory contains machine configuration patches for the Talos cluster.

## Directory Structure

```
patches/
├── global/           # Applied to all nodes
├── controller/       # Applied to control plane nodes only
└── node/            # Node-specific patches
```

## Global Patches

- `cluster-discovery.yaml` - Cluster discovery settings
- `containerd.yaml` - Container runtime configuration
- `cpu-performance.yaml` - CPU performance optimization
- `disable-search-domain.yaml` - DNS search domain configuration
- `hostdns.yaml` - Host DNS settings
- `kubelet.yaml` - Kubelet configuration (max-pods, node IP)
- `local-path-provisioner.yaml` - Local storage mounts
- `metrics-server.yaml` - Metrics server deployment
- `nvidia.yaml` - NVIDIA GPU driver and runtime configuration
- `sysctls.yaml` - Kernel sysctl tuning
- `udev.yaml` - Device permission rules

## Controller Patches

- `api-access.yaml` - KubePrism and Talos API access
- `disable-proxy.yaml` - Disable kube-proxy (using Cilium)
- `etcd-metrics-patch.yaml` - Etcd/scheduler/controller-manager metrics
- `kubelet-certs.yaml` - Kubelet certificate approver

## Node Patches

- `spark-0.yaml` - DGX Spark specific configuration
