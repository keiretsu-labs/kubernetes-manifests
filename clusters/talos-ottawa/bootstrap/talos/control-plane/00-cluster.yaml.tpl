---
cluster:
  allowSchedulingOnControlPlanes: true
{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
---
apiVersion: v1alpha1
kind: KubeAPIServerConfig
certExtraSANs:
  - 192.168.169.25
  - default-kubernetes-ottawa-ingress.keiretsu.ts.net
  - kubernetes-ottawa.keiretsu.ts.net
  - kubernetes.ottawa.rajsingh.info
  - kubernetes-ottawa.default.svc.cluster.local
  - 127.0.0.1
{{- else }}
  apiServer:
    certSANs:
      - 192.168.169.25
      - default-kubernetes-ottawa-ingress.keiretsu.ts.net
      - kubernetes-ottawa.keiretsu.ts.net
      - kubernetes.ottawa.rajsingh.info
      - kubernetes-ottawa.default.svc.cluster.local
      - 127.0.0.1
{{- end }}
