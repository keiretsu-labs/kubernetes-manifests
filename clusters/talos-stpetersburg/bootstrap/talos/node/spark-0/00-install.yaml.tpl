---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/installer/{{ .SchematicID }}:v{{ trimPrefix "v" .TalosVersion }}
provisioning:
  diskSelector:
    match: 'glob("S8C2NG0Y733052", disk.serial) && disk.transport != "" && !disk.readonly && !disk.cdrom'
