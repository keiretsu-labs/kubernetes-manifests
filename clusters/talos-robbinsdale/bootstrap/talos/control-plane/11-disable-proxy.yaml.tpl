---
{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
{{- else }}
cluster:
  proxy:
    disabled: true
{{- end }}
