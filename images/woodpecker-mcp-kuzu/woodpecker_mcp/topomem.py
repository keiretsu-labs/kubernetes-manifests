"""Topology memory: keep vanished services visible instead of silently gone.

A workload deleted mid-incident (not just scaled to 0) disappears from live
discovery - and with it every edge pointing at it, which silently reshapes the
root-cause analysis. Same for a traced service that stops emitting spans. When
WP_TOPOLOGY_MEMORY names a file, each refresh records what it saw; a service
missing from live discovery but seen within WP_TOPOLOGY_MEMORY_TTL seconds is
resurrected as DOWN (with its remembered edges) and flagged in the warnings.

Connector-agnostic: applied to discover() output, so it covers docker, k8s and
traces alike. The file is JSON, written atomically; entries expire after the
TTL, so an intentionally removed service ages out on its own.
"""
import json
import os
import time


def _load(path):
    try:
        with open(path) as f:
            doc = json.load(f)
        return doc.get("services", {}), doc.get("edges", {})
    except (OSError, ValueError):
        return {}, {}


def _save(path, services, edges):
    doc = {"services": services, "edges": edges}
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=1)
    os.replace(tmp, path)


def apply(svc, dep_edges, path, ttl, now=None):
    """Merge remembered-but-vanished services into `svc`/`dep_edges` and update
    the memory file. Returns (svc, dep_edges, warnings). Never raises - memory
    is an enhancement, not a dependency."""
    now = time.time() if now is None else now
    path = os.path.expanduser(path)
    warnings = []
    try:
        mem_services, mem_edges = _load(path)

        # Resurrect recently-seen services that vanished from live discovery.
        resurrected = set()
        for name, entry in mem_services.items():
            if name in svc or now - entry.get("last_seen", 0) > ttl:
                continue
            resurrected.add(name)
            svc[name] = {"name": name, "role": entry.get("role", "app"),
                         "status": "down", "container_state": "missing"}
            warnings.append(
                f"service '{name}' vanished from live topology (deleted?); kept as DOWN "
                f"from topology memory for {int(ttl)}s after last sighting")

        # Record what is live now (resurrected entries keep their original
        # last_seen so they age out); drop expired entries.
        for name, s in svc.items():
            if name not in resurrected:
                mem_services[name] = {"role": s.get("role", "app"), "last_seen": now}
        mem_services = {n: e for n, e in mem_services.items()
                        if now - e.get("last_seen", 0) <= ttl}

        live_edges = {f"{a}|{b}" for a, b in dep_edges}
        for key in live_edges:
            mem_edges[key] = now
        mem_edges = {k: t for k, t in mem_edges.items() if now - t <= ttl}

        # Remembered edges come back ONLY when they touch a resurrected service
        # - deleting a service must not silently erase who depended on it. For
        # edges between two LIVE services the connector is authoritative: an
        # intentionally removed dependency must not be resurrected as a phantom.
        edges = set(map(tuple, dep_edges))
        for key in mem_edges:
            a, _, b = key.partition("|")
            if (a in resurrected or b in resurrected) and a in svc and b in svc:
                edges.add((a, b))

        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        _save(path, mem_services, mem_edges)
        return svc, sorted(edges), warnings
    except Exception as e:
        warnings.append(f"topology memory unavailable ({e})")
        return svc, dep_edges, warnings
