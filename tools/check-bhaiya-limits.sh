#!/usr/bin/env bash
# Assert the Bhaiya public-route protection contract without contacting a cluster.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$ROOT"

if ! python3 -c "import yaml" 2>/dev/null; then
  yaml_site="$(find /workspace/.local/share/nix/root/nix/store -maxdepth 1 -name "*pyyaml*" -not -name "*.drv" -type d 2>/dev/null | head -1)"
  if [ -n "$yaml_site" ]; then
    export PYTHONPATH="$yaml_site/lib/python3.14/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  fi
fi

python3 - <<'PY'
import pathlib

import yaml

path = pathlib.Path("kubernetes/apps/base/k8gb/k8gb-common/config/gslb-bhaiya.yaml")
text = path.read_text()
if "hermes" in text.lower():
    raise SystemExit("Bhaiya limits contract must not change Hermes authorization/proxy scope")

documents = [document for document in yaml.safe_load_all(text) if document]
objects = {
    (document.get("kind"), document.get("metadata", {}).get("namespace"), document.get("metadata", {}).get("name")): document
    for document in documents
}

namespace = "keiretsu-top"
gateway_parent = {
    "group": "gateway.networking.k8s.io",
    "kind": "Gateway",
    "name": "public",
    "namespace": "home",
    "sectionName": "wildcard-keiretsu-top-https",
}


def get(kind, name):
    try:
        return objects[(kind, namespace, name)]
    except KeyError as error:
        raise SystemExit(f"missing {kind} {namespace}/{name}") from error


def refs(policy):
    return {
        (reference.get("group"), reference.get("kind"), reference.get("name"))
        for reference in policy.get("spec", {}).get("targetRefs", [])
    }


def match_signature(match):
    return (
        match.get("method"),
        tuple(
            (header.get("name"), header.get("type"), header.get("value"))
            for header in match.get("headers", [])
        ),
        (
            match.get("path", {}).get("type"),
            match.get("path", {}).get("value"),
        ),
    )


upgrade = get("HTTPRoute", "bhaiya-cdn")
plain = get("HTTPRoute", "bhaiya-cdn-plain")
for route in (upgrade, plain):
    spec = route.get("spec", {})
    if spec.get("parentRefs") != [gateway_parent]:
        raise SystemExit(f"{route['metadata']['name']} must stay on the public Bhaiya listener")
    if spec.get("hostnames") != ["bhaiya.${COMMON_DOMAIN}"]:
        raise SystemExit(f"{route['metadata']['name']} changed the public Bhaiya hostname")
    if spec.get("rules", [{}])[0].get("timeouts", {}).get("request") != "3600s":
        raise SystemExit(f"{route['metadata']['name']} must retain the long request timeout")

upgrade_matches = {
    match_signature(match)
    for match in upgrade["spec"]["rules"][0].get("matches", [])
}
expected_upgrade_matches = {
    (None, (("Upgrade", "RegularExpression", ".+"),), ("PathPrefix", "/")),
    (None, (("Connection", "RegularExpression", "(?i).*upgrade.*"),), ("PathPrefix", "/")),
    ("CONNECT", (), ("PathPrefix", "/")),
}
if upgrade_matches != expected_upgrade_matches:
    raise SystemExit("bhaiya-cdn must retain explicit Upgrade, Connection: upgrade, and CONNECT matches")

plain_matches = plain["spec"]["rules"][0].get("matches", [])
if [match_signature(match) for match in plain_matches] != [
    (None, (), ("PathPrefix", "/"))
]:
    raise SystemExit("bhaiya-cdn-plain must remain the single plain HTTP path")

expected_targets = {
    ("gateway.networking.k8s.io", "HTTPRoute", "bhaiya-cdn"),
    ("gateway.networking.k8s.io", "HTTPRoute", "bhaiya-cdn-plain"),
}
auth = get("SecurityPolicy", "bhaiya-tinyauth")
redirect = get("EnvoyExtensionPolicy", "bhaiya-tinyauth-redirect")
if refs(auth) != expected_targets or refs(redirect) != expected_targets:
    raise SystemExit("Bhaiya auth and redirect policies must cover both split routes")
if "extAuth" not in auth.get("spec", {}) or "authorization" in auth.get("spec", {}):
    raise SystemExit("Bhaiya Tinyauth policy must retain authN-only behavior")

limits = get("BackendTrafficPolicy", "bhaiya-plain-http-limits")
if refs(limits) != {
    ("gateway.networking.k8s.io", "HTTPRoute", "bhaiya-cdn-plain")
}:
    raise SystemExit("Bhaiya limits must target only the plain HTTP route")
rate_rules = limits.get("spec", {}).get("rateLimit", {}).get("local", {}).get("rules", [])
if rate_rules != [{"limit": {"requests": 600, "unit": "Minute"}}]:
    raise SystemExit("Bhaiya plain HTTP route must retain the 600 requests/minute local limit")
if limits.get("spec", {}).get("requestBuffer", {}).get("limit") != "8Mi":
    raise SystemExit("Bhaiya plain HTTP route must retain the 8Mi request-buffer limit")

print("✓ Bhaiya public limits contract")
PY
