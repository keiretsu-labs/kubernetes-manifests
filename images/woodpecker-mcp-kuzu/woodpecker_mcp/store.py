"""Materialized service dependency graph.

Relationship reasoning (deepest-failing-service root cause, blast radius) is
expressed as Cypher and is therefore deterministic and independently queryable.
`GraphStore` is the backend-agnostic interface; `FalkorGraphStore` (default) and
`KuzuGraphStore` (embedded) implement it.
"""
import os
import threading
from abc import ABC, abstractmethod

from .schema import BAD_STATUSES

# Service node columns. Container-level state is folded into one health per service.
_COLUMNS = ["name", "role", "status", "error_rate", "monitoring",
            "container_state", "container_health", "restarts", "pg_up", "scrape_health"]

_MAX_HOPS = 20  # bounds variable-length traversal; real chains are far shorter


class GraphStore(ABC):
    @abstractmethod
    def reset(self): ...
    @abstractmethod
    def upsert_service(self, service: dict): ...
    @abstractmethod
    def add_dependency(self, src: str, dst: str): ...
    @abstractmethod
    def topology(self) -> list: ...
    @abstractmethod
    def roots(self) -> list: ...
    @abstractmethod
    def cascading(self) -> list: ...
    @abstractmethod
    def cyclic_bad(self) -> list: ...
    @abstractmethod
    def blast_radius(self, service: str, direction: str) -> list: ...
    @abstractmethod
    def blind_spots(self) -> list: ...
    @abstractmethod
    def service_health(self, service: str) -> dict: ...

    def bulk_load(self, services, edges):
        """Load many services + edges. Backends override to batch; the default
        loops (fine for embedded backends with no per-query network hop)."""
        for s in services:
            self.upsert_service(s)
        for src, dst in edges:
            self.add_dependency(src, dst)


class FalkorGraphStore(GraphStore):
    """FalkorDB backend (Redis-module graph server; OpenCypher). Schema-free.
    FalkorDB has no `EXISTS { subquery }`, so deepest-failing-service uses a
    list-comprehension over collected descendants.
    """

    def __init__(self, host="localhost", port=6379, graph="woodpecker", password=None):
        from falkordb import FalkorDB
        # Reentrant: build._ingest holds it across reset+load so readers never
        # see a half-built graph; individual queries take it too (same funnel).
        self.lock = threading.RLock()
        self._db = FalkorDB(host=host, port=port, password=password)
        self.graph_name = graph
        self.g = self._db.select_graph(graph)

    def _query(self, q, params=None):
        with self.lock:
            return self.g.query(q, params or {}).result_set

    def reset(self):
        self._query("MATCH (n) DETACH DELETE n")

    @staticmethod
    def _props(service):
        props = {k: service.get(k) for k in _COLUMNS if service.get(k) is not None}
        props["monitoring"] = service.get("monitoring", "ok")
        return props

    def upsert_service(self, service: dict):
        self._query("CREATE (s:Service) SET s += $props", {"props": self._props(service)})

    def add_dependency(self, src: str, dst: str):
        self._query("MATCH (a:Service {name:$a}), (b:Service {name:$b}) "
                    "CREATE (a)-[:DEPENDS_ON]->(b)", {"a": src, "b": dst})

    def bulk_load(self, services, edges):
        # One round trip per statement instead of one per node/edge - the
        # difference between O(N+E) and O(1) network hops on every refresh.
        services = list(services)
        if services:
            self._query("UNWIND $rows AS r CREATE (s:Service) SET s += r",
                        {"rows": [self._props(s) for s in services]})
        edges = [list(e) for e in edges]
        if edges:
            self._query("UNWIND $edges AS e "
                        "MATCH (a:Service {name: e[0]}), (b:Service {name: e[1]}) "
                        "CREATE (a)-[:DEPENDS_ON]->(b)", {"edges": edges})

    def topology(self):
        svc = {r[0]: {"service": r[0], "role": r[1], "status": r[2], "error_rate": r[3],
                      "monitoring": r[4], "depends_on": []}
               for r in self._query(
                   "MATCH (s:Service) RETURN s.name, s.role, s.status, s.error_rate, s.monitoring")}
        for src, dst in self._query("MATCH (a:Service)-[:DEPENDS_ON]->(b:Service) RETURN a.name, b.name"):
            if src in svc:
                svc[src]["depends_on"].append(dst)
        for s in svc.values():
            s["depends_on"].sort()
        return [svc[k] for k in sorted(svc)]

    def _localize(self, keep_bad_count):
        # Collect each bad service's bad descendants; size 0 = root, > 0 = cascading.
        op = "= 0" if keep_bad_count == 0 else "> 0"
        cols = "s.name, s.status, s.error_rate" if keep_bad_count == 0 else "s.name, s.status"
        return self._query(
            "MATCH (s:Service) WHERE s.status IN $bad "
            f"OPTIONAL MATCH (s)-[:DEPENDS_ON*1..{_MAX_HOPS}]->(d:Service) "
            "WITH s, [x IN collect(d) WHERE x.status IN $bad] AS bad_deps "
            f"WHERE size(bad_deps) {op} RETURN {cols}",
            {"bad": BAD_STATUSES})

    def roots(self):
        return [{"service": r[0], "status": r[1], "error_rate": r[2]} for r in self._localize(0)]

    def cascading(self):
        return [{"service": r[0], "status": r[1]} for r in self._localize(1)]

    def cyclic_bad(self):
        # Bad services on a dependency cycle: they can reach themselves. In an
        # all-bad cycle no service qualifies as a pure root (each has a bad
        # descendant), so diagnose falls back to these as joint root candidates.
        rows = self._query(
            "MATCH (s:Service) WHERE s.status IN $bad "
            f"OPTIONAL MATCH (s)-[:DEPENDS_ON*1..{_MAX_HOPS}]->(d:Service) "
            "WITH s, [x IN collect(d) WHERE x.name = s.name] AS self_hits "
            "WHERE size(self_hits) > 0 RETURN s.name, s.status, s.error_rate",
            {"bad": BAD_STATUSES})
        return [{"service": r[0], "status": r[1], "error_rate": r[2]} for r in rows]

    def blast_radius(self, service, direction):
        if direction == "upstream":
            q = (f"MATCH (a:Service)-[:DEPENDS_ON*1..{_MAX_HOPS}]->(b:Service {{name:$s}}) "
                 "RETURN DISTINCT a.name")
        else:
            q = (f"MATCH (b:Service {{name:$s}})-[:DEPENDS_ON*1..{_MAX_HOPS}]->(a:Service) "
                 "RETURN DISTINCT a.name")
        return sorted(r[0] for r in self._query(q, {"s": service}))

    def blind_spots(self):
        rows = self._query("MATCH (s:Service) WHERE s.monitoring = 'MISSING' "
                           "AND NOT (s.status IN $bad) RETURN s.name", {"bad": BAD_STATUSES})
        return sorted(r[0] for r in rows)

    def service_health(self, service):
        rows = self._query(
            "MATCH (s:Service {name:$s}) RETURN s.name, s.role, s.status, s.container_state, "
            "s.container_health, s.restarts, s.error_rate, s.pg_up, s.scrape_health, s.monitoring",
            {"s": service})
        if not rows:
            return {}
        keys = ["name", "role", "status", "container_state", "container_health",
                "restarts", "error_rate", "pg_up", "scrape_health", "monitoring"]
        return {k: v for k, v in zip(keys, rows[0]) if v is not None}

    def has_service(self, service):
        return bool(self._query("MATCH (s:Service {name:$s}) RETURN s.name", {"s": service}))


class KuzuGraphStore(GraphStore):
    """Embedded Kuzu backend (in-process, file-based; Cypher)."""

    def __init__(self, path: str):
        import kuzu
        # Reentrant, and doubles as the thread-safety guard for the single Kuzu
        # Connection (not thread-safe on its own).
        self.lock = threading.RLock()
        self.db = kuzu.Database(path)
        self.conn = kuzu.Connection(self.db)
        self._ensure_schema()

    def _execute(self, query, params=None):
        with self.lock:
            return self.conn.execute(query, params or {})

    def _rows(self, query, params=None):
        with self.lock:
            res = self._execute(query, params)
            out = []
            while res.has_next():
                out.append(res.get_next())
            return out

    def _try(self, query):
        try:
            self._execute(query)
        except Exception:
            pass

    def _ensure_schema(self):
        self._try(
            "CREATE NODE TABLE Service("
            "name STRING, role STRING, status STRING, error_rate DOUBLE, monitoring STRING, "
            "container_state STRING, container_health STRING, restarts INT64, pg_up BOOL, "
            "scrape_health STRING, PRIMARY KEY(name))"
        )
        self._try("CREATE REL TABLE DEPENDS_ON(FROM Service TO Service)")

    def reset(self):
        # Drop the rel table before the node table it references.
        self._try("DROP TABLE DEPENDS_ON")
        self._try("DROP TABLE Service")
        self._ensure_schema()

    def upsert_service(self, service: dict):
        params = {k: service.get(k) for k in _COLUMNS}
        params["monitoring"] = service.get("monitoring", "ok")
        self._execute(
            "CREATE (:Service {name:$name, role:$role, status:$status, error_rate:$error_rate, "
            "monitoring:$monitoring, container_state:$container_state, "
            "container_health:$container_health, restarts:$restarts, pg_up:$pg_up, "
            "scrape_health:$scrape_health})",
            params,
        )

    def add_dependency(self, src: str, dst: str):
        self._execute(
            "MATCH (a:Service {name:$a}), (b:Service {name:$b}) CREATE (a)-[:DEPENDS_ON]->(b)",
            {"a": src, "b": dst},
        )

    def topology(self):
        svc = {r[0]: {"service": r[0], "role": r[1], "status": r[2],
                      "error_rate": r[3], "monitoring": r[4], "depends_on": []}
               for r in self._rows(
                   "MATCH (s:Service) RETURN s.name, s.role, s.status, s.error_rate, s.monitoring")}
        for src, dst in self._rows("MATCH (a:Service)-[:DEPENDS_ON]->(b:Service) RETURN a.name, b.name"):
            if src in svc:
                svc[src]["depends_on"].append(dst)
        for s in svc.values():
            s["depends_on"].sort()
        return [svc[k] for k in sorted(svc)]

    def roots(self):
        rows = self._rows(
            "MATCH (s:Service) WHERE s.status IN $bad "
            f"AND NOT EXISTS {{ MATCH (s)-[:DEPENDS_ON*1..{_MAX_HOPS}]->(d:Service) "
            "WHERE d.status IN $bad } "
            "RETURN s.name, s.status, s.error_rate",
            {"bad": BAD_STATUSES},
        )
        return [{"service": r[0], "status": r[1], "error_rate": r[2]} for r in rows]

    def cascading(self):
        rows = self._rows(
            "MATCH (s:Service) WHERE s.status IN $bad "
            f"AND EXISTS {{ MATCH (s)-[:DEPENDS_ON*1..{_MAX_HOPS}]->(d:Service) "
            "WHERE d.status IN $bad } "
            "RETURN s.name, s.status",
            {"bad": BAD_STATUSES},
        )
        return [{"service": r[0], "status": r[1]} for r in rows]

    def cyclic_bad(self):
        # Bad services on a dependency cycle (can reach themselves) - the root
        # candidates diagnose falls back to when no pure root exists.
        rows = self._rows(
            "MATCH (s:Service) WHERE s.status IN $bad "
            f"AND EXISTS {{ MATCH (s)-[:DEPENDS_ON*1..{_MAX_HOPS}]->(d:Service) "
            "WHERE d.name = s.name } "
            "RETURN s.name, s.status, s.error_rate",
            {"bad": BAD_STATUSES},
        )
        return [{"service": r[0], "status": r[1], "error_rate": r[2]} for r in rows]

    def blast_radius(self, service, direction):
        if direction == "upstream":
            q = (f"MATCH (a:Service)-[:DEPENDS_ON*1..{_MAX_HOPS}]->(b:Service {{name:$s}}) "
                 "RETURN DISTINCT a.name")
        else:
            q = (f"MATCH (b:Service {{name:$s}})-[:DEPENDS_ON*1..{_MAX_HOPS}]->(a:Service) "
                 "RETURN DISTINCT a.name")
        return sorted(r[0] for r in self._rows(q, {"s": service}))

    def blind_spots(self):
        rows = self._rows(
            "MATCH (s:Service) WHERE s.monitoring = 'MISSING' AND NOT (s.status IN $bad) "
            "RETURN s.name",
            {"bad": BAD_STATUSES},
        )
        return sorted(r[0] for r in rows)

    def service_health(self, service):
        rows = self._rows(
            "MATCH (s:Service {name:$s}) RETURN s.name, s.role, s.status, s.container_state, "
            "s.container_health, s.restarts, s.error_rate, s.pg_up, s.scrape_health, s.monitoring",
            {"s": service},
        )
        if not rows:
            return {}
        keys = ["name", "role", "status", "container_state", "container_health",
                "restarts", "error_rate", "pg_up", "scrape_health", "monitoring"]
        return {k: v for k, v in zip(keys, rows[0]) if v is not None}

    def has_service(self, service):
        return bool(self._rows("MATCH (s:Service {name:$s}) RETURN s.name", {"s": service}))


def open_store() -> GraphStore:
    """Open the configured graph backend (WP_GRAPH_BACKEND: falkordb | kuzu)."""
    from . import config
    if config.GRAPH_BACKEND == "kuzu":
        os.makedirs(os.path.dirname(os.path.abspath(config.KUZU_PATH)), exist_ok=True)
        return KuzuGraphStore(config.KUZU_PATH)
    return FalkorGraphStore(config.FALKOR_HOST, config.FALKOR_PORT,
                            config.FALKOR_GRAPH, config.FALKOR_PASSWORD)
