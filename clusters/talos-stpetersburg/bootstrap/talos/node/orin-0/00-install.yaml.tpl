---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/installer/{{ .SchematicID }}:v{{ trimPrefix "v" .TalosVersion }}
provisioning:
  diskSelector:
    match: 'disk.transport != "" && disk.transport == "nvme" && !disk.readonly && !disk.cdrom'
