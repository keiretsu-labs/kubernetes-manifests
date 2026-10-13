---
{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
apiVersion: v1alpha1
kind: KubeAPIServerConfig
certExtraSANs:
  - 192.168.73.25
  - 192.168.73.211
  - default-kubernetes-stpetersburg-ingress.keiretsu.ts.net
  - kubernetes-stpetersburg.keiretsu.ts.net
  - kubernetes.stpetersburg.rajsingh.info
  - kubernetes-stpetersburg.default.svc.cluster.local
  - 127.0.0.1
{{- else }}
cluster:
  apiServer:
    certSANs:
      - 192.168.73.25
      - 192.168.73.211
      - default-kubernetes-stpetersburg-ingress.keiretsu.ts.net
      - kubernetes-stpetersburg.keiretsu.ts.net
      - kubernetes.stpetersburg.rajsingh.info
      - kubernetes-stpetersburg.default.svc.cluster.local
      - 127.0.0.1
{{- end }}
