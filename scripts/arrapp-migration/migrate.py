#!/usr/bin/env python3
# scripts/arrapp-migration/migrate.py
"""
Walks all clusters/talos-*/apps/media/app/*/arrapp.yaml files,
generates replacement files in-place, and writes patch-pvcs.sh.
"""
import sys
from pathlib import Path
import yaml

# Allow importing generators from same directory
sys.path.insert(0, str(Path(__file__).parent))
from generators import (
    generate_app_yaml,
    generate_httproute_yaml,
    generate_storagestack_yaml,
    generate_kustomization_yaml,
)

REPO_ROOT = Path(__file__).parent.parent.parent
CONTEXTS = {
    'talos-robbinsdale': ('robbinsdale', 'robbinsdale-k8s-operator.keiretsu.ts.net'),
    'talos-ottawa': ('ottawa', 'ottawa-k8s-operator.keiretsu.ts.net'),
}

PATCH_CMD = (
    'kubectl patch pvc {pvc} -n media --context {ctx} --type=json '
    "-p='[{{\"op\":\"remove\",\"path\":\"/metadata/ownerReferences\"}}]' 2>/dev/null || true"
)


def parse_arrapp(path: Path) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def parse_kustomization(path: Path) -> tuple[list, str | None]:
    """Returns (resources, namespace_or_None)."""
    with open(path) as f:
        doc = yaml.safe_load(f)
    resources = doc.get('resources', [])
    namespace = doc.get('namespace')
    return resources, namespace


def migrate_app(arrapp_path: Path, location: str) -> str:
    """Generates output files for one app. Returns the config PVC name."""
    doc = parse_arrapp(arrapp_path)
    spec = doc['spec']
    app_dir = arrapp_path.parent

    # Fill in defaults that may be absent in real instances
    spec.setdefault('puid', '0')
    spec.setdefault('pgid', '0')
    spec.setdefault('timezone', 'UTC')
    spec.setdefault('fsGroup', 0)
    spec.setdefault('configMountPath', '/config')
    spec.setdefault('mediaMountPath', '/media-share')
    spec.setdefault('downloadsClaimName', '')
    spec.setdefault('downloadsMountPath', '/downloads')
    spec.setdefault('configStorageSize', '5Gi')
    spec.setdefault('publicGateway', False)
    spec.setdefault('volsyncCopyMethod', 'Snapshot')

    (app_dir / 'app.yaml').write_text(generate_app_yaml(spec))
    (app_dir / 'httproute.yaml').write_text(generate_httproute_yaml(spec))
    (app_dir / 'storagestack.yaml').write_text(generate_storagestack_yaml(spec, location))

    ks_path = app_dir / 'kustomization.yaml'
    existing_resources, namespace = parse_kustomization(ks_path)
    ks_path.write_text(generate_kustomization_yaml(existing_resources, namespace))

    return f"{spec['name']}-config"


def main():
    patch_lines = ['#!/usr/bin/env bash', 'set -e', '']
    pvc_by_context: dict[str, list[str]] = {}

    for cluster, (location, context) in CONTEXTS.items():
        pattern = f'clusters/{cluster}/apps/media/app/*/arrapp.yaml'
        arrapp_files = sorted(REPO_ROOT.glob(pattern))
        if not arrapp_files:
            print(f'WARNING: no arrapp.yaml found for {cluster}')
            continue

        pvc_by_context[context] = []
        for arrapp_path in arrapp_files:
            app_name = arrapp_path.parent.name
            print(f'  {cluster}/{app_name}')
            pvc_name = migrate_app(arrapp_path, location)
            pvc_by_context[context].append(pvc_name)

    # Write patch-pvcs.sh
    for context, pvcs in pvc_by_context.items():
        patch_lines.append(f'echo "=== {context} ==="')
        for pvc in pvcs:
            patch_lines.append(PATCH_CMD.format(pvc=pvc, ctx=context))
        patch_lines.append('')

    script_path = Path(__file__).parent / 'patch-pvcs.sh'
    script_path.write_text('\n'.join(patch_lines) + '\n')
    script_path.chmod(0o755)
    print(f'\nWrote {script_path}')
    print('Next: bash scripts/arrapp-migration/patch-pvcs.sh')


if __name__ == '__main__':
    main()
