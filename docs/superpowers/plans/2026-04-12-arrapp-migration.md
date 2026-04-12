# ArrApp Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace 43 `ArrApp` KRO instances across Robbinsdale and Ottawa with raw Deployment+Service (`app.yaml`), raw HTTPRoute (`httproute.yaml`), and StorageStack KRO primitive (`storagestack.yaml`) via a Python migration script.

**Architecture:** A Python script (`scripts/arrapp-migration/migrate.py`) walks all `arrapp.yaml` files, calls pure generator functions to produce 3 replacement files per app, and emits a shell script (`patch-pvcs.sh`) that removes KRO ownerReferences from live PVCs before the yaml migration commit. Two-step process: run patch script first, then commit generated files.

**Tech Stack:** Python 3 (stdlib + pyyaml), pytest, kubectl, git

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `scripts/arrapp-migration/generators.py` | Create | Pure functions: spec dict → YAML strings |
| `scripts/arrapp-migration/test_generators.py` | Create | pytest tests for all generators |
| `scripts/arrapp-migration/migrate.py` | Create | File walker: reads arrapp.yaml, calls generators, writes output files + patch-pvcs.sh |
| `clusters/talos-*/apps/media/app/*/app.yaml` | Create (43×) | Generated Deployment + Service |
| `clusters/talos-*/apps/media/app/*/httproute.yaml` | Create (43×) | Generated HTTPRoute |
| `clusters/talos-*/apps/media/app/*/storagestack.yaml` | Create (43×) | Generated StorageStack |
| `clusters/talos-*/apps/media/app/*/kustomization.yaml` | Modify (43×) | Replace arrapp.yaml ref with 3 new files |
| `clusters/talos-*/apps/media/app/*/arrapp.yaml` | Delete (43×) | Removed via `git rm` after review |

---

## Task 1: Script skeleton + test harness

**Files:**
- Create: `scripts/arrapp-migration/generators.py`
- Create: `scripts/arrapp-migration/test_generators.py`

- [ ] **Install pytest**

```bash
pip3 install pytest pyyaml
```

- [ ] **Create `scripts/arrapp-migration/generators.py` with stubs**

```python
# scripts/arrapp-migration/generators.py
import yaml
from typing import Optional


def generate_app_yaml(spec: dict) -> str:
    """Generate Deployment + Service YAML from an ArrApp spec dict."""
    raise NotImplementedError


def generate_httproute_yaml(spec: dict) -> str:
    """Generate HTTPRoute YAML from an ArrApp spec dict."""
    raise NotImplementedError


def generate_storagestack_yaml(spec: dict, location: str) -> str:
    """Generate StorageStack YAML from an ArrApp spec dict + cluster location."""
    raise NotImplementedError


def generate_kustomization_yaml(existing_resources: list[str], namespace: Optional[str]) -> str:
    """
    Generate kustomization.yaml replacing arrapp.yaml with 3 new files.
    Preserves non-arrapp.yaml resources (e.g. unas.yaml).
    existing_resources: list of resource paths from original kustomization.
    namespace: value of existing namespace field, or None if absent.
    """
    raise NotImplementedError
```

- [ ] **Create `scripts/arrapp-migration/test_generators.py` with first failing test**

```python
# scripts/arrapp-migration/test_generators.py
import yaml
import pytest
from generators import (
    generate_app_yaml,
    generate_httproute_yaml,
    generate_storagestack_yaml,
    generate_kustomization_yaml,
)

# ── fixtures ──────────────────────────────────────────────────────────────────

SONARR_SPEC = {
    'name': 'sonarr-1080p',
    'image': 'lscr.io/linuxserver/sonarr',
    'tag': '4.0.17',
    'port': 8989,
    'hostname': 'sonarr-1080p',
    'homerName': 'Sonarr 1080p',
    'homerSubtitle': 'TV Series Collection Manager',
    'homerLogo': 'https://raw.githubusercontent.com/walkxcode/dashboard-icons/main/svg/sonarr.svg',
    'configStorageClass': 'ceph-block-replicated',
    'configStorageSize': '5Gi',
    'mediaClaimName': 'media-share',
    'mediaMountPath': '/media-share',
    'volsyncCopyMethod': 'Snapshot',
    'publicGateway': False,
    'puid': '0',
    'pgid': '0',
    'timezone': 'UTC',
    'fsGroup': 0,
    'configMountPath': '/config',
    'downloadsClaimName': '',
    'downloadsMountPath': '/downloads',
}

READARR_SPEC = {
    'name': 'readarr',
    'image': 'lscr.io/linuxserver/readarr',
    'tag': '1.0.1126',
    'port': 8787,
    'hostname': 'readarr',
    'homerName': 'Readarr',
    'homerSubtitle': 'Book Collection Manager',
    'homerLogo': 'https://raw.githubusercontent.com/walkxcode/dashboard-icons/main/svg/readarr.svg',
    'configStorageClass': 'ceph-block-replicated-nvme',
    'configStorageSize': '5Gi',
    'mediaClaimName': 'readarr-books-unas',
    'mediaMountPath': '/books',
    'downloadsClaimName': 'transmission-books-data-unas',
    'downloadsMountPath': '/downloads',
    'volsyncCopyMethod': 'Direct',
    'publicGateway': False,
    'puid': '0',
    'pgid': '0',
    'timezone': 'UTC',
    'fsGroup': 0,
    'configMountPath': '/config',
}

JELLYSEERR_SPEC = {
    'name': 'jellyseerr',
    'image': 'ghcr.io/seerr-team/seerr',
    'tag': 'v3.1.0',
    'port': 5055,
    'hostname': 'jellyseerr',
    'homerName': 'Jellyseerr',
    'homerSubtitle': 'Media Request Manager',
    'homerLogo': 'https://raw.githubusercontent.com/walkxcode/dashboard-icons/main/svg/jellyseerr.svg',
    'configStorageClass': 'ceph-block-replicated-nvme',
    'configStorageSize': '5Gi',
    'mediaClaimName': 'media-share',
    'mediaMountPath': '/media-share',
    'volsyncCopyMethod': 'Direct',
    'publicGateway': True,
    'puid': '0',
    'pgid': '0',
    'timezone': 'UTC',
    'fsGroup': 1000,
    'configMountPath': '/app/config',
    'downloadsClaimName': '',
    'downloadsMountPath': '/downloads',
}

WIZARR_SPEC = {
    'name': 'wizarr',
    'image': 'ghcr.io/wizarrrr/wizarr',
    'tag': 'v2026.4.0',
    'port': 5690,
    'hostname': 'wizarr',
    'homerName': 'Wizarr',
    'homerSubtitle': 'Auth Server',
    'homerLogo': 'https://raw.githubusercontent.com/walkxcode/dashboard-icons/main/svg/wizarr.svg',
    'configStorageClass': 'ceph-block-replicated',
    'configStorageSize': '5Gi',
    'mediaClaimName': 'media-share',
    'mediaMountPath': '/media-share',
    'volsyncCopyMethod': 'Snapshot',
    'publicGateway': False,
    'puid': '1000',
    'pgid': '1000',
    'timezone': 'UTC',
    'fsGroup': 0,
    'configMountPath': '/data',
    'downloadsClaimName': '',
    'downloadsMountPath': '/downloads',
}


# ── app.yaml tests ────────────────────────────────────────────────────────────

def test_app_yaml_basic_deployment():
    result = yaml.safe_load_all(generate_app_yaml(SONARR_SPEC))
    docs = list(result)
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    assert deployment['metadata']['name'] == 'sonarr-1080p'
    assert deployment['spec']['replicas'] == 1
    assert deployment['spec']['strategy']['type'] == 'Recreate'
```

- [ ] **Run test — confirm it fails with NotImplementedError**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py::test_app_yaml_basic_deployment -v
```

Expected: `FAILED` with `NotImplementedError`

- [ ] **Commit**

```bash
git add scripts/arrapp-migration/
git commit -m "chore(arrapp-migration): add script skeleton and test harness"
git push
```

---

## Task 2: Implement `generate_app_yaml()`

**Files:**
- Modify: `scripts/arrapp-migration/generators.py`
- Modify: `scripts/arrapp-migration/test_generators.py`

- [ ] **Implement `generate_app_yaml()` in `generators.py`**

```python
def generate_app_yaml(spec: dict) -> str:
    name = spec['name']
    image = spec['image']
    tag = spec['tag']
    port = int(spec['port'])
    puid = str(spec.get('puid', '0'))
    pgid = str(spec.get('pgid', '0'))
    timezone = spec.get('timezone', 'UTC')
    fs_group = int(spec.get('fsGroup', 0))
    config_mount = spec.get('configMountPath', '/config')
    media_claim = spec['mediaClaimName']
    media_mount = spec.get('mediaMountPath', '/media-share')
    downloads_claim = spec.get('downloadsClaimName', '')
    downloads_mount = spec.get('downloadsMountPath', '/downloads')

    volume_mounts = [
        {'name': 'config', 'mountPath': config_mount},
        {'name': 'media', 'mountPath': media_mount},
    ]
    volumes = [
        {'name': 'config', 'persistentVolumeClaim': {'claimName': f'{name}-config'}},
        {'name': 'media', 'persistentVolumeClaim': {'claimName': media_claim}},
    ]
    if downloads_claim:
        volume_mounts.append({'name': 'downloads', 'mountPath': downloads_mount})
        volumes.append({'name': 'downloads', 'persistentVolumeClaim': {'claimName': downloads_claim}})

    pod_spec = {
        'containers': [{
            'name': name,
            'image': f'{image}:{tag}',
            'ports': [{'name': 'http', 'containerPort': port, 'protocol': 'TCP'}],
            'env': [
                {'name': 'PUID', 'value': puid},
                {'name': 'GUID', 'value': pgid},
                {'name': 'TZ', 'value': timezone},
            ],
            'volumeMounts': volume_mounts,
        }],
        'volumes': volumes,
    }
    if fs_group:
        pod_spec['securityContext'] = {'fsGroup': fs_group}

    deployment = {
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {'name': name},
        'spec': {
            'replicas': 1,
            'selector': {'matchLabels': {'app': name}},
            'strategy': {'type': 'Recreate'},
            'template': {
                'metadata': {'labels': {'app': name}},
                'spec': pod_spec,
            },
        },
    }

    service = {
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {'name': name},
        'spec': {
            'selector': {'app': name},
            'ports': [{'name': 'http', 'port': port, 'protocol': 'TCP', 'targetPort': port}],
        },
    }

    return '---\n' + yaml.dump(deployment, default_flow_style=False, sort_keys=False) + \
           '---\n' + yaml.dump(service, default_flow_style=False, sort_keys=False)
```

- [ ] **Add full app.yaml test coverage in `test_generators.py`**

```python
def test_app_yaml_image_and_port():
    docs = list(yaml.safe_load_all(generate_app_yaml(SONARR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    container = deployment['spec']['template']['spec']['containers'][0]
    assert container['image'] == 'lscr.io/linuxserver/sonarr:4.0.17'
    assert container['ports'][0]['containerPort'] == 8989


def test_app_yaml_env_vars():
    docs = list(yaml.safe_load_all(generate_app_yaml(SONARR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    env = {e['name']: e['value'] for e in deployment['spec']['template']['spec']['containers'][0]['env']}
    assert env['PUID'] == '0'
    assert env['GUID'] == '0'   # ArrApp uses GUID not PGID
    assert 'PGID' not in env
    assert env['TZ'] == 'UTC'


def test_app_yaml_config_pvc_name():
    docs = list(yaml.safe_load_all(generate_app_yaml(SONARR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    volumes = deployment['spec']['template']['spec']['volumes']
    config_vol = next(v for v in volumes if v['name'] == 'config')
    assert config_vol['persistentVolumeClaim']['claimName'] == 'sonarr-1080p-config'


def test_app_yaml_no_downloads_volume_by_default():
    docs = list(yaml.safe_load_all(generate_app_yaml(SONARR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    volume_names = [v['name'] for v in deployment['spec']['template']['spec']['volumes']]
    assert 'downloads' not in volume_names


def test_app_yaml_downloads_volume_when_set():
    docs = list(yaml.safe_load_all(generate_app_yaml(READARR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    volumes = deployment['spec']['template']['spec']['volumes']
    mounts = deployment['spec']['template']['spec']['containers'][0]['volumeMounts']
    assert any(v['persistentVolumeClaim']['claimName'] == 'transmission-books-data-unas'
               for v in volumes if v['name'] == 'downloads')
    assert any(m['mountPath'] == '/downloads' for m in mounts if m['name'] == 'downloads')


def test_app_yaml_fsgroup_set_when_nonzero():
    docs = list(yaml.safe_load_all(generate_app_yaml(JELLYSEERR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    assert deployment['spec']['template']['spec']['securityContext']['fsGroup'] == 1000


def test_app_yaml_no_security_context_when_fsgroup_zero():
    docs = list(yaml.safe_load_all(generate_app_yaml(SONARR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    assert 'securityContext' not in deployment['spec']['template']['spec']


def test_app_yaml_custom_config_mount():
    docs = list(yaml.safe_load_all(generate_app_yaml(JELLYSEERR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    mounts = deployment['spec']['template']['spec']['containers'][0]['volumeMounts']
    config_mount = next(m for m in mounts if m['name'] == 'config')
    assert config_mount['mountPath'] == '/app/config'


def test_app_yaml_custom_puid_pgid():
    docs = list(yaml.safe_load_all(generate_app_yaml(WIZARR_SPEC)))
    deployment = next(d for d in docs if d['kind'] == 'Deployment')
    env = {e['name']: e['value'] for e in deployment['spec']['template']['spec']['containers'][0]['env']}
    assert env['PUID'] == '1000'
    assert env['GUID'] == '1000'


def test_app_yaml_service():
    docs = list(yaml.safe_load_all(generate_app_yaml(SONARR_SPEC)))
    service = next(d for d in docs if d['kind'] == 'Service')
    assert service['metadata']['name'] == 'sonarr-1080p'
    assert service['spec']['selector'] == {'app': 'sonarr-1080p'}
    assert service['spec']['ports'][0]['port'] == 8989
    assert service['spec']['ports'][0]['targetPort'] == 8989
```

- [ ] **Run tests — all should pass**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py -k "app_yaml" -v
```

Expected: 10 PASSED

- [ ] **Commit**

```bash
git add scripts/arrapp-migration/
git commit -m "feat(arrapp-migration): implement generate_app_yaml with full test coverage"
git push
```

---

## Task 3: Implement `generate_httproute_yaml()`

**Files:**
- Modify: `scripts/arrapp-migration/generators.py`
- Modify: `scripts/arrapp-migration/test_generators.py`

- [ ] **Add failing tests**

```python
# ── httproute.yaml tests ──────────────────────────────────────────────────────

def test_httproute_basic():
    docs = list(yaml.safe_load_all(generate_httproute_yaml(SONARR_SPEC)))
    route = docs[0]
    assert route['kind'] == 'HTTPRoute'
    assert route['metadata']['name'] == 'sonarr-1080p'


def test_httproute_hostname_uses_flux_var():
    docs = list(yaml.safe_load_all(generate_httproute_yaml(SONARR_SPEC)))
    route = docs[0]
    assert route['spec']['hostnames'] == ['sonarr-1080p.${CLUSTER_DOMAIN}']


def test_httproute_parent_refs_private_and_ts():
    docs = list(yaml.safe_load_all(generate_httproute_yaml(SONARR_SPEC)))
    route = docs[0]
    parent_names = [p['name'] for p in route['spec']['parentRefs']]
    assert 'private' in parent_names
    assert 'ts' in parent_names
    assert 'public' not in parent_names


def test_httproute_public_gateway_adds_public():
    docs = list(yaml.safe_load_all(generate_httproute_yaml(JELLYSEERR_SPEC)))
    route = docs[0]
    parent_names = [p['name'] for p in route['spec']['parentRefs']]
    assert 'public' in parent_names


def test_httproute_backend_ref():
    docs = list(yaml.safe_load_all(generate_httproute_yaml(SONARR_SPEC)))
    route = docs[0]
    backend = route['spec']['rules'][0]['backendRefs'][0]
    assert backend['name'] == 'sonarr-1080p'
    assert backend['port'] == 8989


def test_httproute_homer_annotations():
    docs = list(yaml.safe_load_all(generate_httproute_yaml(SONARR_SPEC)))
    route = docs[0]
    ann = route['metadata']['annotations']
    assert ann['item.homer.rajsingh.info/name'] == 'Sonarr 1080p'
    assert ann['item.homer.rajsingh.info/subtitle'] == 'TV Series Collection Manager'
    assert ann['item.homer.rajsingh.info/logo'].startswith('https://')
    assert ann['item.homer.rajsingh.info/keywords'] == 'tv, series, automation'
    assert ann['service.homer.rajsingh.info/name'] == 'Media'
    assert ann['service.homer.rajsingh.info/icon'] == 'fas fa-tv'
```

- [ ] **Run tests — confirm they fail**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py -k "httproute" -v
```

Expected: 6 FAILED with `NotImplementedError`

- [ ] **Implement `generate_httproute_yaml()` in `generators.py`**

```python
def generate_httproute_yaml(spec: dict) -> str:
    name = spec['name']
    hostname = spec['hostname']
    port = int(spec['port'])
    public_gateway = spec.get('publicGateway', False)
    homer_name = spec.get('homerName', name)
    homer_subtitle = spec.get('homerSubtitle', '')
    homer_logo = spec.get('homerLogo', '')

    parent_refs = [
        {'group': 'gateway.networking.k8s.io', 'kind': 'Gateway', 'name': 'private', 'namespace': 'home'},
        {'group': 'gateway.networking.k8s.io', 'kind': 'Gateway', 'name': 'ts', 'namespace': 'home'},
    ]
    if public_gateway:
        parent_refs.append(
            {'group': 'gateway.networking.k8s.io', 'kind': 'Gateway', 'name': 'public', 'namespace': 'home'}
        )

    route = {
        'apiVersion': 'gateway.networking.k8s.io/v1',
        'kind': 'HTTPRoute',
        'metadata': {
            'name': name,
            'annotations': {
                'item.homer.rajsingh.info/name': homer_name,
                'item.homer.rajsingh.info/subtitle': homer_subtitle,
                'item.homer.rajsingh.info/logo': homer_logo,
                'item.homer.rajsingh.info/keywords': 'tv, series, automation',
                'service.homer.rajsingh.info/name': 'Media',
                'service.homer.rajsingh.info/icon': 'fas fa-tv',
            },
        },
        'spec': {
            'parentRefs': parent_refs,
            'hostnames': [f'{hostname}.${{CLUSTER_DOMAIN}}'],
            'rules': [{
                'backendRefs': [{'group': '', 'kind': 'Service', 'name': name, 'port': port, 'weight': 1}],
                'matches': [{'path': {'type': 'PathPrefix', 'value': '/'}}],
            }],
        },
    }

    return '---\n' + yaml.dump(route, default_flow_style=False, sort_keys=False)
```

- [ ] **Run tests — all should pass**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py -k "httproute" -v
```

Expected: 6 PASSED

- [ ] **Commit**

```bash
git add scripts/arrapp-migration/
git commit -m "feat(arrapp-migration): implement generate_httproute_yaml with full test coverage"
git push
```

---

## Task 4: Implement `generate_storagestack_yaml()`

**Files:**
- Modify: `scripts/arrapp-migration/generators.py`
- Modify: `scripts/arrapp-migration/test_generators.py`

- [ ] **Add failing tests**

```python
# ── storagestack.yaml tests ───────────────────────────────────────────────────

def test_storagestack_basic():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(SONARR_SPEC, 'ottawa')))
    ss = docs[0]
    assert ss['kind'] == 'StorageStack'
    assert ss['apiVersion'] == 'storage.keiretsu.ts.net/v1alpha1'


def test_storagestack_name_appends_config():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(SONARR_SPEC, 'ottawa')))
    ss = docs[0]
    assert ss['metadata']['name'] == 'sonarr-1080p-config'
    assert ss['spec']['name'] == 'sonarr-1080p-config'


def test_storagestack_location_label():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(SONARR_SPEC, 'ottawa')))
    ss = docs[0]
    assert ss['metadata']['labels']['keiretsu.ts.net/location'] == 'ottawa'


def test_storagestack_s3_path():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(SONARR_SPEC, 'ottawa')))
    ss = docs[0]
    assert ss['spec']['s3Path'] == 'media/sonarr-1080p-config'


def test_storagestack_schedule():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(SONARR_SPEC, 'ottawa')))
    ss = docs[0]
    assert ss['spec']['schedule'] == '0 4 * * *'


def test_storagestack_restore_mode_backup_only():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(SONARR_SPEC, 'ottawa')))
    ss = docs[0]
    assert ss['spec']['restoreMode'] == 'backup-only'


def test_storagestack_copy_method_snapshot_ottawa():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(SONARR_SPEC, 'ottawa')))
    ss = docs[0]
    assert ss['spec']['copyMethod'] == 'Snapshot'


def test_storagestack_copy_method_direct_robbinsdale():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(READARR_SPEC, 'robbinsdale')))
    ss = docs[0]
    assert ss['spec']['copyMethod'] == 'Direct'


def test_storagestack_storage_class_and_size():
    docs = list(yaml.safe_load_all(generate_storagestack_yaml(SONARR_SPEC, 'ottawa')))
    ss = docs[0]
    assert ss['spec']['storageClass'] == 'ceph-block-replicated'
    assert ss['spec']['size'] == '5Gi'
```

- [ ] **Run tests — confirm they fail**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py -k "storagestack" -v
```

Expected: 9 FAILED with `NotImplementedError`

- [ ] **Implement `generate_storagestack_yaml()` in `generators.py`**

```python
def generate_storagestack_yaml(spec: dict, location: str) -> str:
    name = spec['name']
    storage_class = spec.get('configStorageClass', 'ceph-block-replicated')
    size = spec.get('configStorageSize', '5Gi')
    copy_method = spec.get('volsyncCopyMethod', 'Snapshot')

    ss = {
        'apiVersion': 'storage.keiretsu.ts.net/v1alpha1',
        'kind': 'StorageStack',
        'metadata': {
            'name': f'{name}-config',
            'labels': {'keiretsu.ts.net/location': location},
        },
        'spec': {
            'name': f'{name}-config',
            'size': size,
            'storageClass': storage_class,
            's3Path': f'media/{name}-config',
            'schedule': '0 4 * * *',
            'restoreMode': 'backup-only',
            'copyMethod': copy_method,
        },
    }

    return '---\n' + yaml.dump(ss, default_flow_style=False, sort_keys=False)
```

- [ ] **Run tests — all should pass**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py -k "storagestack" -v
```

Expected: 9 PASSED

- [ ] **Commit**

```bash
git add scripts/arrapp-migration/
git commit -m "feat(arrapp-migration): implement generate_storagestack_yaml with full test coverage"
git push
```

---

## Task 5: Implement `generate_kustomization_yaml()`

**Files:**
- Modify: `scripts/arrapp-migration/generators.py`
- Modify: `scripts/arrapp-migration/test_generators.py`

- [ ] **Add failing tests**

```python
# ── kustomization.yaml tests ──────────────────────────────────────────────────

def test_kustomization_replaces_arrapp():
    result = generate_kustomization_yaml(['./arrapp.yaml'], 'media')
    doc = yaml.safe_load(result)
    resources = doc['resources']
    assert 'arrapp.yaml' not in resources
    assert './arrapp.yaml' not in resources
    assert 'app.yaml' in resources
    assert 'httproute.yaml' in resources
    assert 'storagestack.yaml' in resources


def test_kustomization_preserves_extra_resources():
    result = generate_kustomization_yaml(['arrapp.yaml', 'unas.yaml'], None)
    doc = yaml.safe_load(result)
    resources = doc['resources']
    assert 'unas.yaml' in resources
    assert 'app.yaml' in resources
    assert 'arrapp.yaml' not in resources


def test_kustomization_preserves_namespace():
    result = generate_kustomization_yaml(['./arrapp.yaml'], 'media')
    doc = yaml.safe_load(result)
    assert doc['namespace'] == 'media'


def test_kustomization_omits_namespace_when_absent():
    result = generate_kustomization_yaml(['arrapp.yaml', 'unas.yaml'], None)
    doc = yaml.safe_load(result)
    assert 'namespace' not in doc


def test_kustomization_idempotent_on_rerun():
    # Second run: input already has the 3 new files instead of arrapp.yaml
    result = generate_kustomization_yaml(
        ['app.yaml', 'httproute.yaml', 'storagestack.yaml', 'unas.yaml'], None
    )
    doc = yaml.safe_load(result)
    resources = doc['resources']
    # Should not duplicate the 3 files
    assert resources.count('app.yaml') == 1
    assert resources.count('httproute.yaml') == 1
    assert resources.count('storagestack.yaml') == 1
    assert 'unas.yaml' in resources
```

- [ ] **Run tests — confirm they fail**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py -k "kustomization" -v
```

Expected: 4 FAILED with `NotImplementedError`

- [ ] **Implement `generate_kustomization_yaml()` in `generators.py`**

```python
def generate_kustomization_yaml(existing_resources: list, namespace: Optional[str]) -> str:
    # Strip arrapp.yaml and the 3 generated files (idempotent on re-run)
    MANAGED = {'arrapp.yaml', 'app.yaml', 'httproute.yaml', 'storagestack.yaml'}
    other_resources = [
        r for r in existing_resources
        if r.lstrip('./') not in MANAGED
    ]
    resources = ['app.yaml', 'httproute.yaml', 'storagestack.yaml'] + other_resources

    doc = {
        'apiVersion': 'kustomize.config.k8s.io/v1beta1',
        'kind': 'Kustomization',
        'resources': resources,
    }
    if namespace:
        # Insert namespace after kind
        doc = {
            'apiVersion': 'kustomize.config.k8s.io/v1beta1',
            'kind': 'Kustomization',
            'namespace': namespace,
            'resources': resources,
        }

    return '---\n' + yaml.dump(doc, default_flow_style=False, sort_keys=False)
```

- [ ] **Run tests — all should pass**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py -k "kustomization" -v
```

Expected: 4 PASSED

- [ ] **Run full test suite — all tests should pass**

```bash
cd scripts/arrapp-migration && python3 -m pytest test_generators.py -v
```

Expected: 30 PASSED

- [ ] **Commit**

```bash
git add scripts/arrapp-migration/
git commit -m "feat(arrapp-migration): implement generate_kustomization_yaml with test coverage"
git push
```

---

## Task 6: Implement `migrate.py` main + `patch-pvcs.sh` generation

**Files:**
- Create: `scripts/arrapp-migration/migrate.py`

- [ ] **Implement `migrate.py`**

```python
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
```

- [ ] **Run migrate.py in dry-run mode — verify output for one app without committing**

```bash
cd /path/to/kubernetes-manifests
python3 scripts/arrapp-migration/migrate.py
```

Expected output: lines like `  talos-ottawa/sonarr-1080p`, `  talos-robbinsdale/sonarr`, etc., ending with `Wrote scripts/arrapp-migration/patch-pvcs.sh`

- [ ] **Spot-check 3 generated files**

```bash
# Ottawa app — no downloads, Snapshot
cat clusters/talos-ottawa/apps/media/app/sonarr-1080p/app.yaml
cat clusters/talos-ottawa/apps/media/app/sonarr-1080p/storagestack.yaml

# Robbinsdale app with downloads volume
cat clusters/talos-robbinsdale/apps/media/app/readarr/app.yaml

# App with publicGateway + fsGroup
cat clusters/talos-robbinsdale/apps/media/app/jellyseerr/httproute.yaml
cat clusters/talos-robbinsdale/apps/media/app/jellyseerr/app.yaml

# App with unas.yaml — kustomization must preserve it
cat clusters/talos-robbinsdale/apps/media/app/prowlarr/kustomization.yaml
```

Verify for each:
- `sonarr-1080p/storagestack.yaml`: `copyMethod: Snapshot`, `location: ottawa`
- `readarr/app.yaml`: has `downloads` volume mounting `transmission-books-data-unas`
- `jellyseerr/httproute.yaml`: has `public` in parentRefs
- `jellyseerr/app.yaml`: has `securityContext.fsGroup: 1000`, `configMountPath: /app/config`
- `prowlarr/kustomization.yaml`: includes both `unas.yaml` and the 3 new files, no `arrapp.yaml`

- [ ] **Commit migration script + patch-pvcs.sh**

```bash
git add scripts/arrapp-migration/migrate.py scripts/arrapp-migration/patch-pvcs.sh
git commit -m "feat(arrapp-migration): add migrate.py and patch-pvcs.sh"
git push
```

---

## Task 7: Run patch-pvcs.sh — protect live PVCs

- [ ] **Run patch-pvcs.sh against both clusters**

```bash
bash scripts/arrapp-migration/patch-pvcs.sh
```

Expected: kubectl patch output for each PVC, no errors (the `|| true` means already-patched PVCs won't abort the script)

- [ ] **Verify ownerReferences removed on both clusters**

```bash
for ctx in robbinsdale-k8s-operator.keiretsu.ts.net ottawa-k8s-operator.keiretsu.ts.net; do
  echo "=== $ctx ==="
  kubectl get pvc -n media --context $ctx \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.ownerReferences}{"\n"}{end}' \
    | grep -- "-config"
done
```

Expected: all `-config` PVC lines show empty `[]` or no ownerReferences field.

---

## Task 8: Commit generated yaml files and push

- [ ] **Stage generated files and remove arrapp.yaml files**

```bash
git add clusters/talos-ottawa/apps/media/app/
git add clusters/talos-robbinsdale/apps/media/app/
git rm clusters/talos-ottawa/apps/media/app/*/arrapp.yaml
git rm clusters/talos-robbinsdale/apps/media/app/*/arrapp.yaml
```

- [ ] **Verify the diff looks right**

```bash
git status --short | head -40
git diff --cached --stat
```

Expected: ~43 deletions of `arrapp.yaml`, ~129 additions of `app.yaml`/`httproute.yaml`/`storagestack.yaml`, ~43 modifications of `kustomization.yaml`

- [ ] **Commit and push**

```bash
git commit -m "refactor: migrate ArrApp instances to StorageStack + raw manifests"
git push
```

---

## Task 9: Verify reconciliation

- [ ] **Wait ~2 minutes for Flux to reconcile, then check KRO StorageStack status**

```bash
kubectl get storagestack -n media \
  --context robbinsdale-k8s-operator.keiretsu.ts.net
kubectl get storagestack -n media \
  --context ottawa-k8s-operator.keiretsu.ts.net
```

Expected: all StorageStack resources show `ACTIVE / Ready: True`

- [ ] **Verify Deployments are running**

```bash
kubectl get deployments -n media \
  --context robbinsdale-k8s-operator.keiretsu.ts.net | grep -E "sonarr|radarr|bazarr|lidarr|prowlarr|readarr|audioarr|wizarr|jellyseerr|overseerr|sabnzbd|autobrr|tautulli"
kubectl get deployments -n media \
  --context ottawa-k8s-operator.keiretsu.ts.net | grep -E "sonarr|radarr|bazarr|lidarr|prowlarr|wizarr|jellyseerr|overseerr|sabnzbd|autobrr|tautulli"
```

Expected: all deployments show `1/1 READY`

- [ ] **Spot-check HTTPRoutes are accepted**

```bash
kubectl get httproute -n media \
  --context ottawa-k8s-operator.keiretsu.ts.net | head -10
```

Expected: routes show `Accepted` status
