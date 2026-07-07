"""TopologySource backed by local Docker Compose projects.

Discovers services/containers from `docker inspect`, and dependency edges from
two signals merged: (1) compose's `com.docker.compose.depends_on` label, and
(2) env-var host references (URI forms, service DNS, and bare HOST/ADDR style
vars - see sources.base.references_host) - the real "who talks to whom".

Scope: a named project (WP_COMPOSE_PROJECT) yields bare service-name nodes;
blank (the default) discovers EVERY compose project on the host with nodes
qualified as "project/service" - mirroring the k8s connector's "ns/name" -
so same-named services in unrelated projects never fold into one node, and
env-reference edges are only inferred within a project (compose networks are
per-project by default).
"""
import json
import subprocess

from .base import TopologySource, references_host, role_for


class DockerComposeTopology(TopologySource):
    def __init__(self, project=None):
        """project: compose project to inspect; empty/None = every compose
        project on the host (containers carrying the compose project label)."""
        from .. import config
        self.project = config.COMPOSE_PROJECT if project is None else project

    def _inspect_all(self):
        label = (f"label=com.docker.compose.project={self.project}" if self.project
                 else "label=com.docker.compose.project")
        # timeout: a hung docker daemon must fail the refresh, not hang the tool call
        names = subprocess.check_output(
            ["docker", "ps", "-a", "--filter", label, "--format", "{{.Names}}"],
            text=True, timeout=15,
        ).split()
        if not names:
            return []
        return json.loads(subprocess.check_output(["docker", "inspect", *names], text=True, timeout=15))

    def discover(self):
        infos = self._inspect_all()
        multi = not self.project   # all projects -> qualify node names

        def node(project, service):
            return f"{project}/{service}" if multi else service

        # Known services per project = those with containers PLUS those other
        # services declare via depends_on. A service scaled to 0 has no
        # container at all; it must stay in the graph (as down), not silently
        # vanish with its edges.
        names_by_project = {}
        for c in infos:
            labels = c["Config"].get("Labels") or {}
            project = labels.get("com.docker.compose.project", "")
            svc = labels.get("com.docker.compose.service", c["Name"].lstrip("/"))
            names_by_project.setdefault(project, set()).add(svc)
            for part in filter(None, labels.get("com.docker.compose.depends_on", "").split(",")):
                dep = part.split(":")[0]
                if dep:
                    names_by_project[project].add(dep)

        services, containers, deps = {}, [], set()
        for c in infos:
            name = c["Name"].lstrip("/")
            labels = c["Config"].get("Labels") or {}
            project = labels.get("com.docker.compose.project", "")
            svc_bare = labels.get("com.docker.compose.service", name)
            svc = node(project, svc_bare)
            state = c["State"]["Status"]
            health = (c["State"].get("Health") or {}).get("Status")
            restarts = c.get("RestartCount", 0)
            image = c["Config"].get("Image", "")

            services.setdefault(svc, {"name": svc, "role": role_for(svc_bare, image),
                                      "scrape_intent": labels.get("prometheus.io/scrape") == "true"})
            containers.append({"name": name, "service": svc, "state": state,
                               "health": health, "restarts": restarts, "image": image})

            for part in filter(None, labels.get("com.docker.compose.depends_on", "").split(",")):
                dep = part.split(":")[0]
                if dep and dep != svc_bare:
                    deps.add((svc, node(project, dep)))

            # Env references resolve only within the same project - compose
            # networks are per-project, so a bare host name cannot reach a
            # same-named service in another project.
            local = names_by_project.get(project, set())
            for env in (c["Config"].get("Env") or []):
                key, _, val = env.partition("=")
                for other in local:
                    if other != svc_bare and references_host(val, other, name=key):
                        deps.add((svc, node(project, other)))

        # Declared-but-containerless services become nodes; _collapse marks them down.
        for project, bare_names in names_by_project.items():
            for bare in bare_names:
                services.setdefault(node(project, bare),
                                    {"name": node(project, bare), "role": role_for(bare)})

        return list(services.values()), containers, sorted(deps)
