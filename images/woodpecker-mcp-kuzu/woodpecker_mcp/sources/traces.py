"""TopologySource backed by distributed traces.

Traces record who actually calls whom, which is exactly the dependency edges the
graph needs - real call edges instead of inferred ones. This reads Jaeger's
/api/dependencies endpoint (parent -> child service edges, parent depends on
child).

Health does NOT come from traces. A service emitting spans is up, so discovered
services are marked healthy here; real failure signals (error rate, db liveness)
come from the paired MetricsSource. Use this together with a metrics source, not
alone.

Tempo variant: Tempo's service graph is exposed as Prometheus metrics
(traces_service_graph_request_total{client,server}) by its metrics-generator, so
a Tempo topology is a PromQL query against WP_PROM_URL rather than this endpoint.
"""
import json
import time
import urllib.parse
import urllib.request

from .. import config
from .base import TopologySource


class JaegerTopology(TopologySource):
    def __init__(self, url=None, lookback_seconds=None):
        self.url = (url or config.JAEGER_URL).rstrip("/")
        self.lookback = int(lookback_seconds or config.TRACES_LOOKBACK)

    def _dependencies(self):
        end_ms = int(time.time() * 1000)
        params = {"endTs": end_ms, "lookback": self.lookback * 1000}
        url = f"{self.url}/api/dependencies?" + urllib.parse.urlencode(params)
        with urllib.request.urlopen(url, timeout=8) as r:
            return json.load(r).get("data") or []

    def discover(self):
        names, edges = set(), set()
        for d in self._dependencies():
            parent, child = d.get("parent"), d.get("child")
            if not parent or not child:
                continue
            names.update((parent, child))
            if parent != child:  # drop self-calls
                edges.add((parent, child))
        services = [{"name": n, "role": "app"} for n in sorted(names)]
        # Traces carry no container state; emitting spans means up. The paired
        # MetricsSource supplies the real failure status.
        containers = [{"name": n, "service": n, "state": "running", "health": "healthy",
                       "restarts": 0, "image": None} for n in sorted(names)]
        return services, containers, sorted(edges)
