"""Deterministic root-cause analysis over the materialized graph.

ROOT CAUSE = the DEEPEST failing service: unhealthy, with all its own
dependencies healthy. Everything else unhealthy is cascading fallout. Root/
cascading/cycle localization is Cypher; the per-symptom causal chain is a BFS
shortest path over one topology snapshot (fetching all edges once beats a
path-enumeration query per symptom x root, which is exponential in dense graphs).

Two cases have no pure root and must never read as "healthy":
  - an all-bad dependency cycle (every member has a bad descendant): the cycle
    members become joint root candidates;
  - incomplete health signals (a metrics backend down mid-incident): a clean
    graph downgrades to "degraded", not a confident all-clear.
"""
from collections import deque

from .schema import BAD_STATUSES


def _sorted(items):
    return sorted(items, key=lambda x: x["service"])


def _shortest_path(adj, src, dst):
    """BFS over DEPENDS_ON adjacency; deterministic (neighbors pre-sorted).
    Returns [src, ..., dst] or None."""
    if src == dst:
        return [src]
    prev = {src: None}
    q = deque([src])
    while q:
        u = q.popleft()
        for v in adj.get(u, ()):
            if v in prev:
                continue
            prev[v] = u
            if v == dst:
                path = [dst]
                while prev[path[-1]] is not None:
                    path.append(prev[path[-1]])
                return list(reversed(path))
            q.append(v)
    return None


def _chain(adj, status, src, root_names):
    """Shortest chain from a cascading symptom to the nearest root (ties break
    on root-name order), rendered as 'a[STATUS] -> b[STATUS]'."""
    best = None
    for rn in root_names:
        p = _shortest_path(adj, src, rn)
        if p and (best is None or len(p) < len(best)):
            best = p
    if not best:
        return None
    return " -> ".join(f"{n}[{(status.get(n) or '?').upper()}]" for n in best)


def diagnose(store, warnings=None):
    warnings = list(warnings or [])
    roots = store.roots()
    blind = store.blind_spots()

    # One snapshot for all path reasoning: adjacency + status per service.
    # Failure propagates only through FAILING services, so causal reachability
    # and chains run on the bad-status subgraph - a path through a healthy hop
    # is not a causal path (the healthy service is absorbing, not propagating).
    topo = store.topology()
    status = {t["service"]: t["status"] for t in topo}
    bad = {n for n, s in status.items() if s in BAD_STATUSES}
    adj = {t["service"]: [d for d in t["depends_on"] if d in bad]   # sorted stays sorted
           for t in topo if t["service"] in bad}

    # Cycle members that can causally reach a pure root are fallout of it; the
    # rest are root candidates in their own right (an all-bad cycle has no pure
    # root).
    root_names = [r["service"] for r in roots]
    cycle_roots = [c for c in store.cyclic_bad()
                   if c["service"] not in root_names
                   and not any(_shortest_path(adj, c["service"], rn) for rn in root_names)]

    if not roots and not cycle_roots:
        cascading = store.cascading()
        if cascading:
            # Bad services exist but no root was localizable (should not happen
            # in practice; chains longer than the hop bound could). Never report
            # healthy here.
            return {
                "verdict": "incident", "page": True,
                "root_causes": [],
                "cascading": [{"service": c["service"], "status": c["status"], "chain": None}
                              for c in _sorted(cascading)],
                "blind_spots": blind, "warnings": warnings,
                "summary": (f"INCIDENT - {len(cascading)} service(s) are failing but no root "
                            "could be localized from the dependency graph. Investigate the "
                            "failing set directly. PAGE."),
            }
        if blind:
            return {
                "verdict": "no-incident", "page": False,
                "root_causes": [], "cascading": [], "blind_spots": blind,
                "warnings": warnings,
                "summary": (f"NO INCIDENT - observability blind spot. {', '.join(blind)} "
                            "is healthy but not being scraped; visibility is lost, the "
                            "service itself is fine. Do NOT page."),
            }
        if warnings:
            return {
                "verdict": "degraded", "page": False,
                "root_causes": [], "cascading": [], "blind_spots": [],
                "warnings": warnings,
                "summary": ("DEGRADED - no failing services detected, but health signals "
                            "are incomplete: " + "; ".join(warnings) + ". Treat this "
                            "all-clear with caution."),
            }
        return {"verdict": "healthy", "page": False, "root_causes": [], "cascading": [],
                "blind_spots": [], "warnings": [],
                "summary": "All services healthy - no incident."}

    root_causes = [{
        "service": r["service"], "status": r["status"], "error_rate": r["error_rate"],
        "why": f"{(r['status'] or '?').upper()} and all of its own dependencies are healthy",
    } for r in _sorted(roots)] + [{
        "service": c["service"], "status": c["status"], "error_rate": c.get("error_rate"),
        "why": (f"{(c['status'] or '?').upper()} and part of a dependency cycle of failing "
                "services - the root cause lies within this cycle"),
    } for c in _sorted(cycle_roots)]

    all_root_names = [r["service"] for r in root_causes]
    cycle_names = {c["service"] for c in cycle_roots}
    cascading = [{"service": c["service"], "status": c["status"],
                  "chain": _chain(adj, status, c["service"], all_root_names)}
                 for c in _sorted(store.cascading()) if c["service"] not in cycle_names]

    cycle_note = (f" {len(cycle_roots)} root candidate(s) form a dependency cycle - "
                  "the true root lies within it." if cycle_roots else "")
    return {
        "verdict": "incident", "page": True,
        "root_causes": root_causes, "cascading": cascading, "blind_spots": blind,
        "warnings": warnings,
        "summary": (f"INCIDENT - root cause: {', '.join(all_root_names)} (deepest failing "
                    f"service in the dependency chain).{cycle_note} {len(cascading)} downstream "
                    f"service(s) are cascading symptoms. PAGE."),
    }
