"""Populate the graph store - from live connectors (refresh) or a static file
(ingest_static, for offline relationship study / tests).
"""
from . import config, topomem
from .schema import derive_container_status, worse
from .sources import metrics_source, topology_source


def _resolve(name, svc, namespace=None):
    """Map a metrics-side name (scrape target, series label) to a graph node.
    Handles namespace-qualified nodes: exact key, then <ns>/<name> from the
    target's own namespace label, then a unique */<name> suffix match."""
    if not name:
        return None
    if name in svc:
        return name
    if namespace and f"{namespace}/{name}" in svc:
        return f"{namespace}/{name}"
    matches = [k for k in svc if k.endswith(f"/{name}")]
    return matches[0] if len(matches) == 1 else None


def _target_node(t, svc):
    """Resolve a scrape target to a graph node - by service/app/job label, then
    by pod-name prefix (kube-prometheus targets often lack a service label)."""
    node = _resolve(t.get("service"), svc, t.get("namespace"))
    if node:
        return node
    pod = t.get("pod") or ""
    best = None
    for key in svc:
        bare = key.rsplit("/", 1)[-1]
        if pod.startswith(bare + "-") and (best is None or len(bare) > len(best[0])):
            if t.get("namespace") and "/" in key and not key.startswith(t["namespace"] + "/"):
                continue
            best = (bare, key)
    return best[1] if best else None


def _collapse(services, containers):
    """Fold container-level state into one logical health per service."""
    svc = {s["name"]: {"name": s["name"], "role": s.get("role", "app"), "status": "unknown"}
           for s in services}
    seen, ready = set(), set()
    for c in containers:
        s = svc.get(c["service"])
        if not s:
            continue
        seen.add(c["service"])
        st = derive_container_status(c["state"], c["health"])
        if st == "healthy":
            ready.add(c["service"])
        s["status"] = st if s["status"] == "unknown" else worse(s["status"], st)
        s["container_state"] = c["state"]
        s["container_health"] = c["health"]
        s["restarts"] = c["restarts"]
    for name, s in svc.items():
        # A service with no containers at all (e.g. scaled to 0 replicas) is down,
        # not unknown - "silently missing" is exactly the failure worth catching.
        if name not in seen:
            s["status"] = "down"
            s["container_state"] = "missing"
        # "starting" is only benign while something is still serving. All
        # replicas starting = nothing ready = a real outage, not a rollout.
        elif s["status"] == "starting" and name not in ready:
            s["status"] = "unhealthy"
    return svc


def refresh(store, topology=None, metrics=None):
    """Rebuild the graph from live sources. Always-current (cheap at this scale).

    Returns a list of warning strings for health signals that could not be
    collected - a dead metrics backend must degrade the verdict, not silently
    pass as "no data" (which used to flag every monitored service MISSING and
    could answer "do NOT page" mid-incident).
    """
    topology = topology or topology_source()
    metrics = metrics or metrics_source()
    services, containers, dep_edges = topology.discover()
    svc = _collapse(services, containers)
    warnings = []

    # Topology memory: services that vanished from live discovery come back as
    # DOWN (with their edges) until unseen for the TTL.
    if config.TOPOLOGY_MEMORY:
        svc, dep_edges, mem_warnings = topomem.apply(
            svc, dep_edges, config.TOPOLOGY_MEMORY, config.TOPOLOGY_MEMORY_TTL)
        warnings += mem_warnings

    # scrape targets -> monitoring health + blind-spot flag
    monitored = set()
    try:
        targets = metrics.targets()
        targets_ok = True
    except Exception as e:
        targets, targets_ok = [], False
        warnings.append(f"scrape targets unavailable ({e}); blind-spot detection skipped")
    for t in targets:
        node = _target_node(t, svc)
        if node:
            svc[node]["scrape_health"] = t["health"]
            monitored.add(node)
    # Only flag blind spots when the target list was actually fetched -
    # otherwise a metrics outage reads as "every service lost monitoring".
    # Expectation: the explicit WP_MONITORED_SERVICES list if set, else AUTO -
    # the scrape intent the topology itself declares (annotations/labels).
    if targets_ok:
        if config.MONITORED_SERVICES:
            expected = {_resolve(n, svc) for n in config.MONITORED_SERVICES}
        else:
            expected = {s["name"] for s in services if s.get("scrape_intent")}
        for node in expected:
            if node and node in svc and node not in monitored:
                svc[node]["monitoring"] = "MISSING"
        # visibility, not an alert: neither declared nor scraped
        for node in svc:
            if node not in monitored and node not in expected:
                svc[node].setdefault("monitoring", "none")

    # database liveness (the exporter target may be up while the DB itself is
    # down). Attaches to the WP_DB_SERVICE node (default "db").
    try:
        up = metrics.db_up()
        if up is not None:
            node = _resolve(config.DB_SERVICE, svc)
            if node is None:
                warnings.append(
                    f"db liveness: WP_DB_SERVICE '{config.DB_SERVICE}' is missing or "
                    "ambiguous in the graph; check skipped")
            else:
                db = svc[node]
                db["pg_up"] = up
                if not up:
                    db["status"] = worse(db["status"], "unhealthy")
    except Exception as e:
        warnings.append(f"db liveness check failed ({e})")

    # per-service error rate -> "erroring" (functional failure container health misses)
    try:
        for name, rate in metrics.error_rates().items():
            node = _resolve(name, svc)
            if node:
                svc[node]["error_rate"] = rate
                if rate > config.ERROR_RATE_THRESHOLD and svc[node]["status"] == "healthy":
                    svc[node]["status"] = "erroring"
    except Exception as e:
        warnings.append(f"error rates unavailable ({e}); 'erroring' detection skipped")

    _ingest(store, svc.values(), dep_edges)
    return warnings


def ingest_static(store, data):
    """Populate from a plain dict (e.g. parsed JSON) - for studying relationships
    without live infra. Shape: {"services": [{name, role, status, error_rate,
    monitoring, ...}], "dependencies": [[src, dst], ...]}."""
    services = data.get("services", [])
    edges = [tuple(e) for e in data.get("dependencies", [])]
    _ingest(store, services, edges)
    return store


def _ingest(store, services, dep_edges):
    services = list(services)
    names = {s["name"] for s in services}
    edges = [(src, dst) for src, dst in dep_edges if src in names and dst in names]
    # The (reentrant) lock spans reset+load so readers never see a half-built graph.
    with store.lock:
        store.reset()
        store.bulk_load(services, edges)
