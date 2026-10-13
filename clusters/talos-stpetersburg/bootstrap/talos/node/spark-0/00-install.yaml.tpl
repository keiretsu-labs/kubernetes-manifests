---
machine:
  install:
    disk:
      $patch: delete
    diskSelector:
      serial: "S8C2NG0Y733052"
    image: factory.talos.dev/installer/{{ .SchematicID }}:v{{ trimPrefix "v" .TalosVersion }}
