---
{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  diskSelector:
    match: 'glob("2316E6CC4FC6", disk.serial) && disk.transport != "" && !disk.readonly && !disk.cdrom'
{{- else }}
machine:
  install:
    disk:
      $patch: delete
    diskSelector:
      serial: "2316E6CC4FC6"
{{- end }}
