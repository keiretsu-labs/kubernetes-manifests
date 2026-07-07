"""TopologySource backed by Kubernetes (via `kubectl`, mirroring the Docker
connector's shell-out style - zero extra deps).

Maps k8s objects onto the same graph vocabulary as the Docker connector:
  Deployment / StatefulSet / DaemonSet -> service node
  Pod                                  -> container node (replicas = many pods)
  Service (kind) selectors             -> name aliases for edge inference
  env refs                             -> depends_on edges

Namespaces: one (WP_K8S_NAMESPACE), a comma list, or "*" for all minus
WP_K8S_EXCLUDE_NAMESPACES (WP_K8S_NAMESPACES). With more than one namespace,
node names are namespace-qualified ("shop/web") and cross-namespace edges come
from service-DNS references (orders.shop.svc...).

Edges come from env values that reference another service as a network host -
literal `value:`, values resolved from ConfigMaps (`valueFrom.configMapKeyRef`
and `envFrom.configMapRef`), URI forms, k8s service DNS, and bare HOST/ADDR
style vars (see sources.base.references_host). Values may name either the
workload or the Service object in front of it (selector-matched to the
workload). Secret-backed envs are never read.

Scrape intent: a workload whose pod template carries the
`prometheus.io/scrape: "true"` annotation is marked `scrape_intent`, which
drives auto blind-spot detection (declared minus actually-scraped).

Pod status is normalized to the docker-like (state, health) the graph builder
understands, aggregated across ALL containers in the pod; terminating pods are
ignored (a rolling deploy is not an outage) and creating pods are transitional.

`kubectl` must be on PATH with a readable kubeconfig (or, in a pod, an
in-cluster ServiceAccount that can get/list deployments, statefulsets,
daemonsets, pods, services and configmaps - see examples/k8s-deployment.yaml;
missing optional grants degrade those signals instead of failing).
"""
import json
import re
import subprocess

from .base import TopologySource, references_host, role_for

_WORKLOAD_KINDS = ("deployments", "statefulsets", "daemonsets")
_BAD_REASONS = ("CrashLoopBackOff", "Error", "ImagePullBackOff", "ErrImagePull",
                "RunContainerError")
# Benign Pending reasons: a pod that is coming up, not one that is stuck.
_STARTING_REASONS = ("ContainerCreating", "PodInitializing")

# k8s service DNS reference: <name>.<namespace>.svc[.cluster.local...]
# Anchored to URI authority positions ('//' or '@') or a value/list start -
# never a bare '/' (that would match URL path segments).
_FQDN = re.compile(r"(?:^|//|@|[,\s])([a-z0-9-]+)\.([a-z0-9-]+)\.svc(?=[.:/]|$)")


def _pod_status(pod):
    """Normalize a Pod to (state, health, restarts) in docker terms, aggregated
    over all its containers: worst waiting-reason wins, restarts are the max,
    ready means every container is ready. Pods still pulling/initializing map
    to 'created' (-> transitional 'starting'), so a rolling deploy does not
    read as an outage; a Pending pod with no such reason (e.g. unschedulable)
    still reads as down."""
    status = pod.get("status", {})
    phase = status.get("phase")
    cs = status.get("containerStatuses") or []
    restarts = max((c.get("restartCount", 0) for c in cs), default=0)
    ready = bool(cs) and all(c.get("ready", False) for c in cs)
    reasons = [((c.get("state") or {}).get("waiting") or {}).get("reason") for c in cs]

    if any(r in _BAD_REASONS for r in reasons):
        return "restarting", "unhealthy", restarts
    if phase == "Running":
        return "running", ("healthy" if ready else "unhealthy"), restarts
    if phase == "Pending" and cs and all(r in _STARTING_REASONS for r in reasons):
        return "created", None, restarts
    # Failed / stuck Pending (unschedulable) / Unknown -> treat as down
    return "exited", "unhealthy", restarts


def _owner_workload(pod):
    """Workload name from ownerReferences: Pod -> ReplicaSet '<deploy>-<hash>'
    -> Deployment, or directly StatefulSet/DaemonSet. Helm-style pods label
    app.kubernetes.io/name with the CHART name, not the release-prefixed
    workload name - ownership is the reliable mapping."""
    for ref in (pod["metadata"].get("ownerReferences") or []):
        kind, name = ref.get("kind"), ref.get("name", "")
        if kind == "ReplicaSet" and "-" in name:
            return name.rsplit("-", 1)[0]
        if kind in ("StatefulSet", "DaemonSet"):
            return name
    return None


def _env_pairs(container, configmaps):
    """Yield (name, value) for a container's env, resolving ConfigMap refs.
    Secret refs are skipped on purpose."""
    for e in (container.get("env") or []):
        name = e.get("name", "")
        if e.get("value"):
            yield name, e["value"]
            continue
        ref = (e.get("valueFrom") or {}).get("configMapKeyRef") or {}
        cm, key = ref.get("name"), ref.get("key")
        if cm in configmaps and key in configmaps[cm]:
            yield name, configmaps[cm][key]
    for ef in (container.get("envFrom") or []):
        cm = (ef.get("configMapRef") or {}).get("name")
        prefix = ef.get("prefix", "")
        for k, v in (configmaps.get(cm) or {}).items():
            yield prefix + k, v


def _selector_matches(selector, labels):
    return bool(selector) and all(labels.get(k) == v for k, v in selector.items())


class KubernetesTopology(TopologySource):
    def __init__(self, namespaces="default", context="", exclude=()):
        if isinstance(namespaces, str):
            namespaces = [namespaces]
        self.namespaces = [n for n in namespaces if n]
        self.context = context
        self.exclude = set(exclude)

    def _kubectl_json(self, kind, namespace=None, all_namespaces=False):
        cmd = ["kubectl", "get", kind, "-o", "json"]
        cmd[1:1] = ["-A"] if all_namespaces else ["-n", namespace]
        if self.context:
            cmd[1:1] = ["--context", self.context]
        out = subprocess.check_output(cmd, text=True, timeout=15)
        return json.loads(out)

    def _try_kubectl_json(self, kind, namespace=None, all_namespaces=False):
        """Optional kinds: RBAC may not grant them - degrade, don't fail."""
        try:
            return self._kubectl_json(kind, namespace, all_namespaces)
        except Exception:
            return {"items": []}

    def _items(self, kind, optional=False):
        """Items of `kind` across the configured namespaces, exclusions applied."""
        fetch = self._try_kubectl_json if optional else self._kubectl_json
        if self.namespaces == ["*"]:
            items = fetch(kind, all_namespaces=True)["items"]
        else:
            items = [it for ns in self.namespaces for it in fetch(kind, namespace=ns)["items"]]
        return [it for it in items if it["metadata"].get("namespace") not in self.exclude]

    def discover(self):
        multi = self.namespaces == ["*"] or len(self.namespaces) > 1

        def node(ns, name):
            return f"{ns}/{name}" if multi else name

        # Workloads -> service nodes. Deployments are the baseline (hard failure
        # = connector error); StatefulSets/DaemonSets are additive.
        svc_names, services = set(), []
        tmpl_labels = {}  # (ns, workload) -> pod template labels, for Service selectors
        for kind in _WORKLOAD_KINDS:
            for w in self._items(kind, optional=kind != "deployments"):
                ns, name = w["metadata"].get("namespace", ""), w["metadata"]["name"]
                key = node(ns, name)
                if key in svc_names:
                    continue
                svc_names.add(key)
                tmpl = w.get("spec", {}).get("template", {})
                spec = tmpl.get("spec", {})
                image = (spec.get("containers") or [{}])[0].get("image", "")
                annotations = tmpl.get("metadata", {}).get("annotations", {}) or {}
                tmpl_labels[(ns, name)] = tmpl.get("metadata", {}).get("labels", {}) or {}
                services.append({
                    "name": key, "role": role_for(name, image),
                    "scrape_intent": annotations.get("prometheus.io/scrape") == "true",
                })

        # Per-namespace lookup of bare name -> node key, extended with Service
        # (kind) aliases: an env var usually names the Service, not the workload.
        by_ns = {}
        for ns, name in tmpl_labels:
            by_ns.setdefault(ns, {})[name] = node(ns, name)
        for s in self._items("services", optional=True):
            ns, sname = s["metadata"].get("namespace", ""), s["metadata"]["name"]
            selector = (s.get("spec") or {}).get("selector") or {}
            for (wns, wname), labels in tmpl_labels.items():
                if wns == ns and _selector_matches(selector, labels):
                    by_ns.setdefault(ns, {}).setdefault(sname, node(wns, wname))
                    break

        configmaps = {}  # (ns, cm-name) -> data
        for cm in self._items("configmaps", optional=True):
            configmaps[(cm["metadata"].get("namespace", ""), cm["metadata"]["name"])] = \
                cm.get("data") or {}

        containers, deps = [], set()
        for p in self._items("pods", optional=False):
            if p["metadata"].get("deletionTimestamp"):
                continue  # terminating (rolling deploy, scale-down): not a health signal
            ns = p["metadata"].get("namespace", "")
            labels = p["metadata"].get("labels", {})
            # First candidate that names a known workload wins. Ownership is
            # authoritative when present (Helm pods label the chart name, not
            # the release-prefixed workload name); labels are the fallback for
            # connectors/pods without ownerReferences.
            candidates = [_owner_workload(p), labels.get("app"),
                          labels.get("app.kubernetes.io/name"), p["metadata"]["name"]]
            svc = next((node(ns, c) for c in candidates
                        if c and node(ns, c) in svc_names), None)
            if svc is None:
                continue  # skip stray pods not owned by a known workload
            state, health, restarts = _pod_status(p)
            spec_containers = p["spec"].get("containers", [])
            image = spec_containers[0].get("image", "") if spec_containers else ""
            containers.append({"name": p["metadata"]["name"], "service": svc, "state": state,
                               "health": health, "restarts": restarts, "image": image})
            ns_cms = {name: data for (cns, name), data in configmaps.items() if cns == ns}
            local = by_ns.get(ns, {})
            for c in spec_containers:
                for key, val in _env_pairs(c, ns_cms):
                    # same-namespace: workload names and Service aliases
                    for other_bare, other_node in local.items():
                        if other_node != svc and references_host(val, other_bare, name=key):
                            deps.add((svc, other_node))
                    # cross-namespace: explicit service-DNS references
                    for m in _FQDN.finditer(val):
                        tname, tns = m.group(1), m.group(2)
                        target = by_ns.get(tns, {}).get(tname)
                        if target and target != svc:
                            deps.add((svc, target))

        return services, containers, sorted(deps)
