---
cluster:
  etcd:
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
---
apiVersion: v1alpha1
kind: KubeControllerManagerConfig
extraArgs:
  bind-address: 0.0.0.0
---
apiVersion: v1alpha1
kind: KubeSchedulerConfig
extraArgs:
  bind-address: 0.0.0.0
config:
  profiles:
    - schedulerName: default-scheduler
      plugins:
        score:
          disabled:
            - name: TaintToleration
{{- else }}
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
    config:
      profiles:
        - schedulerName: default-scheduler
          plugins:
            score:
              disabled:
                - name: TaintToleration
{{- end }}
