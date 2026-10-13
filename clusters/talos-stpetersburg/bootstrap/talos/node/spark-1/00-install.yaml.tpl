---
{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/installer/{{ .SchematicID }}:v{{ trimPrefix "v" .TalosVersion }}
provisioning:
  diskSelector:
    match: 'disk.transport != "" && disk.transport == "nvme" && !disk.readonly && !disk.cdrom'
{{- else }}
machine:
  install:
    disk:
      $patch: delete
    diskSelector:
      type: nvme
    image: factory.talos.dev/installer/{{ .SchematicID }}:v{{ trimPrefix "v" .TalosVersion }}
{{- end }}
