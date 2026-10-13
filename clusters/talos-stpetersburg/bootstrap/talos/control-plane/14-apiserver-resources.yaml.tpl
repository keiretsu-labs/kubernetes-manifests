---
{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
apiVersion: v1alpha1
kind: KubeAPIServerConfig
resources:
  requests:
    cpu: 200m
    memory: 2400Mi
{{- else }}
cluster:
  apiServer:
    resources:
      requests:
        cpu: 200m
        memory: 2400Mi
{{- end }}
