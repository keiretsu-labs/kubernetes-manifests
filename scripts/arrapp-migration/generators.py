# scripts/arrapp-migration/generators.py
import yaml
from typing import Optional


def generate_app_yaml(spec: dict) -> str:
    """Generate Deployment + Service YAML from an ArrApp spec dict."""
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


def generate_httproute_yaml(spec: dict) -> str:
    """Generate HTTPRoute YAML from an ArrApp spec dict."""
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


def generate_storagestack_yaml(spec: dict, location: str) -> str:
    """Generate StorageStack YAML from an ArrApp spec dict + cluster location."""
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


def generate_kustomization_yaml(existing_resources: list[str], namespace: Optional[str]) -> str:
    """
    Generate kustomization.yaml replacing arrapp.yaml with 3 new files.
    Preserves non-arrapp.yaml resources (e.g. unas.yaml).
    existing_resources: list of resource paths from original kustomization.
    namespace: value of existing namespace field, or None if absent.
    """
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
