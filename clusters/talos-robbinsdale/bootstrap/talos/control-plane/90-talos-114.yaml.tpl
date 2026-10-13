{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
---
machine:
  nodeLabels:
    node.kubernetes.io/exclude-from-external-load-balancers: ""
---
apiVersion: v1alpha1
kind: KubeAPIServerConfig
startupProbes: false
---
apiVersion: v1alpha1
kind: KubeAuthenticationConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubePrismConfig
$patch: delete
{{- end }}
