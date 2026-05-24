# Talos Patches

This directory contains configuration patches that are applied to the Talos cluster configuration.

## Directory Structure

- `global/` - Patches applied to all nodes (control plane and workers)
- `controller/` - Patches applied only to control plane nodes
- `worker/` - Patches applied only to worker nodes (when added)

## Global Patches

- `cluster-discovery.yaml` - Enables cluster discovery mechanisms
- `containerd.yaml` - Containerd runtime configuration
- `cpu-performance.yaml` - CPU performance tuning
- `disable-search-domain.yaml` - Disables DNS search domain
- `hostdns.yaml` - Host DNS configuration
- `kubelet.yaml` - Kubelet configuration and feature gates
- `local-path-provisioner.yaml` - Mounts for local path provisioner
- `machine-logging.yaml` - Machine log shipping
- `metrics-server.yaml` - Deploys metrics server
- `sysctls.yaml` - Kernel sysctl tuning
- `udev.yaml` - udev rules

## Controller Patches

- `amd.yaml` - AMD-specific tuning for MS-A2 nodes
- `api-access.yaml` - KubePrism configuration for API access
- `disable-proxy.yaml` - Disables kube-proxy (for Cilium)
- `etcd-metrics-patch.yaml` - etcd metrics endpoint
- `kubelet-certs.yaml` - Kubelet certificate approver

## Node Patches

- `shiro-intel.yaml` - Intel-specific tuning for shiro worker

## Adding New Patches

1. Create a new YAML file in the appropriate directory
2. Add the patch file reference to `talconfig.yaml`
3. Regenerate configuration: `mise run genconfig`
4. Apply to cluster: `mise run apply`

## Patch Format

Patches follow the Talos machine configuration schema:
```yaml
machine:
  network:
    # network configuration
cluster:
  # cluster configuration
```

See [Talos Configuration Reference](https://www.talos.dev/latest/reference/configuration/) for all available options.

## Notes

- These patches are applied by talhelper when generating configurations
- Patches can reference SOPS-encrypted values from `talsecret.sops.yaml`
- See [SOPS Documentation](https://github.com/getsops/sops) for encryption details