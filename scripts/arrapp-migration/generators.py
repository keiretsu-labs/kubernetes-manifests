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
