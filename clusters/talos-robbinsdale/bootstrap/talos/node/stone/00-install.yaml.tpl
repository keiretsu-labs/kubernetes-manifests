---
{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  diskSelector:
    match: 'glob("S5P2NG0R940019Z", disk.serial) && disk.transport != "" && !disk.readonly && !disk.cdrom'
{{- else }}
machine:
  install:
    disk:
      $patch: delete
    diskSelector:
      serial: "S5P2NG0R940019Z"
{{- end }}
