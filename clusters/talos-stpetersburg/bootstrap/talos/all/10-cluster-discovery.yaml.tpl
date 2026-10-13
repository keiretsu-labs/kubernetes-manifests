{{- if not (semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion)) }}
cluster:
  discovery:
    enabled: true
    registries:
      kubernetes:
        # Disabled: kubelet creds (system:node:*) cannot list nodes since k8s
        # 1.32 Node Authorizer tightening — produces a noisy "node watch error"
        # on the Talos dashboard every reconcile. Service registry handles
        # discovery (single-node here anyway).
        disabled: true
      service:
        disabled: false
{{- end }}
