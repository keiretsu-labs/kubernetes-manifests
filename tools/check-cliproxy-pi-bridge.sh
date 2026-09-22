#!/usr/bin/env bash
# Assert the source-level Pi bridge alias contract without contacting a cluster.
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
import os
import pathlib
import re

import yaml

path = pathlib.Path("kubernetes/apps/base/cliproxy/cliproxy/app/deployment.yaml")
documents = list(yaml.safe_load_all(path.read_text()))
deployment = next(
    document
    for document in documents
    if document.get("kind") == "Deployment" and document["metadata"]["name"] == "cliproxy"
)
containers = deployment["spec"]["template"]["spec"]["containers"]
init_containers = deployment["spec"]["template"]["spec"].get("initContainers", [])
render_config = next(container for container in init_containers if container["name"] == "render-config")
render_script = render_config["args"][0]
rendered_config_match = re.search(
    r"(?ms)^[ \t]*cat > /config/config\.yaml <<EOF\n(.*?)^[ \t]*EOF[ \t]*$",
    render_script,
)
if rendered_config_match is None:
    raise SystemExit("render-config must write the CLIProxy configuration heredoc")
rendered_config = yaml.safe_load(rendered_config_match.group(1))
glm_payload_override = {
    "models": [{"name": "vllm/GLM-5.3-Flash-EXL3", "protocol": "openai"}],
    "params": {"messages.#(role==\"developer\")#.role": "system"},
}
if glm_payload_override not in (rendered_config.get("payload") or {}).get("override", []):
    raise SystemExit("GLM must rewrite every developer message to system before its OpenAI route")

providers_path = pathlib.Path("kubernetes/apps/base/cliproxy/cliproxy/app/providers/providers.yaml")
providers = yaml.safe_load(providers_path.read_text())
vllm_provider = next(
    provider
    for provider in providers["openai-compatibility"]
    if provider.get("name") == "vllm"
)
glm_provider_model = next(
    model
    for model in vllm_provider["models"]
    if model.get("alias") == "GLM-5.3-Flash-EXL3"
)
if glm_provider_model.get("thinking") != {"levels": ["low", "medium", "high"]}:
    raise SystemExit(
        "GLM must declare its live low/medium/high thinking levels"
    )

sync = next(container for container in containers if container["name"] == "pi-bridge-sync")
script = sync["args"][0]
sentinel = "ready.unlink(missing_ok=True)"
if sentinel not in script:
    raise SystemExit("pi-bridge-sync bootstrap sentinel is missing")

os.environ["API_KEY"] = "test-api-key"
os.environ["MANAGEMENT_KEY"] = "test-management-key"
namespace = {"__name__": "cliproxy_pi_bridge_contract"}
exec(compile(script.split(sentinel, 1)[0], str(path), "exec"), namespace)

fallback = "codex-subscription/vllm-fallback"
source = "codex-subscription/gpt-5.6-luna"
if namespace["metadata_alias_sources"].get(fallback) != source:
    raise SystemExit(f"{fallback} must resolve metadata from {source}")

glm_alias = "vllm/GLM-5.3-Flash-EXL3"
glm_source = "vllm/GLM-5.3-Flash-EXL3"
if namespace["metadata_alias_sources"].get(glm_alias) != glm_source:
    raise SystemExit(f"{glm_alias} must resolve metadata from {glm_source}")
if namespace["metadata_override"](glm_alias) != {
    "context_window": 1048576,
    "max_tokens": 8192,
    "name": "GLM-5.3 Flash EXL3",
    "reasoning": True,
}:
    raise SystemExit("GLM alias metadata must describe the active serving profile")

namespace["fetch_json"] = lambda url: {
    "data": [{"id": "GLM-5.3-Flash-EXL3"}]
}
glm_sources = namespace["route_sources"]({glm_alias})
if glm_sources.get(glm_alias, {}).get("id") != "GLM-5.3-Flash-EXL3":
    raise SystemExit("GLM catalog did not resolve its canonical upstream source")

if not re.search(
    r'(?ms)oauth-model-alias:\s*\n\s*codex:\s*\n\s*- name: "gpt-5\.6-luna"\s*\n\s*alias: "vllm-fallback"',
    path.read_text(),
):
    raise SystemExit("CLIProxy fallback alias and metadata source are no longer aligned")

seen = []
def resolve_models_dev(entries, index, route_source):
    seen.append(route_source)
    return {"context_window": 1050000, "max_tokens": 128000, "reasoning": True}

namespace["resolve_models_dev"] = resolve_models_dev
metadata = namespace["resolved_metadata"](fallback, "codex", None, [], {})
if metadata != {"context_window": 1050000, "max_tokens": 128000, "reasoning": True}:
    raise SystemExit(f"fallback metadata was not resolved: {metadata!r}")
if seen != [{"id": "gpt-5.6-luna", "provider": {"id": "codex"}, "direct": {}}]:
    raise SystemExit(f"fallback metadata used the wrong source: {seen!r}")

# A configured compatible-provider route must not inherit an old alias
# override when its live upstream source is unavailable. Otherwise a stale
# vLLM route remains selectable even after the serving workload disappears.
if namespace["resolved_metadata"](glm_alias, "vllm", None, [], {}) is not None:
    raise SystemExit("unavailable vLLM route inherited stale metadata")

print("✓ cliproxy Pi bridge metadata and GLM payload contract")
PY
