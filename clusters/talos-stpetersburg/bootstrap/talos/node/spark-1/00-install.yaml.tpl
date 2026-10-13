---
machine:
  install:
    disk:
      $patch: delete
    diskSelector:
      type: nvme
    image: factory.talos.dev/installer/{{ .SchematicID }}:v{{ trimPrefix "v" .TalosVersion }}
