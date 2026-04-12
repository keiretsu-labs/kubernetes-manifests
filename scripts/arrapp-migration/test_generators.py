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
