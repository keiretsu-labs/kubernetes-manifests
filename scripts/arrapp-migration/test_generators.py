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
