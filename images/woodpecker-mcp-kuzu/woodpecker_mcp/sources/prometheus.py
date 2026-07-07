"""MetricsSource backed by a Prometheus HTTP API (stdlib only - just a URL).

Also works unchanged against any PromQL-compatible backend - point the URL at
Thanos, Cortex, Grafana Mimir, VictoriaMetrics, or Grafana Cloud. The queries
are configurable (metric names vary by app/exporter); a non-PromQL backend
(Datadog, New Relic, CloudWatch) implements the same MetricsSource interface in
its own query language.
"""
import json
import urllib.parse
import urllib.request

from .. import config
from .base import MetricsSource


class PrometheusSource(MetricsSource):
    def __init__(self, url=None, error_rate_query=None, error_rate_label=None, db_up_query=None):
        self.url = (url or config.PROM_URL).rstrip("/")
        self.error_rate_query = error_rate_query or config.ERROR_RATE_QUERY
        self.error_rate_label = error_rate_label or config.ERROR_RATE_LABEL
        # "" disables the DB check; None means "use the configured default".
        self.db_up_query = config.DB_UP_QUERY if db_up_query is None else db_up_query

    def _get(self, path, params=None):
        u = f"{self.url}{path}"
        if params:
            u += "?" + urllib.parse.urlencode(params)
        with urllib.request.urlopen(u, timeout=5) as r:
            return json.load(r)

    def _query(self, expr):
        d = self._get("/api/v1/query", {"query": expr})
        return d["data"]["result"] if d.get("status") == "success" else []

    def targets(self):
        d = self._get("/api/v1/targets")
        out = []
        for t in d["data"]["activeTargets"]:
            lb = t.get("labels", {})
            out.append({
                "job": lb.get("job"),
                # kube-prometheus targets often lack a `service` label but carry
                # app/namespace/pod - build.refresh resolves those to graph nodes.
                "service": lb.get("service") or lb.get("app") or lb.get("job"),
                "namespace": lb.get("namespace"),
                "pod": lb.get("pod"),
                "health": t.get("health"),
                "endpoint": t.get("scrapeUrl"),
            })
        return out

    def error_rates(self):
        out = {}
        for r in self._query(self.error_rate_query):
            name = r.get("metric", {}).get(self.error_rate_label)
            if name is None:
                continue
            try:
                out[name] = round(float(r["value"][1]), 3)
            except (KeyError, ValueError, IndexError):
                continue
        return out

    def db_up(self):
        if not self.db_up_query:
            return None
        res = self._query(self.db_up_query)
        if not res:
            return None
        try:
            return res[0]["value"][1] == "1"
        except (KeyError, IndexError):
            return None
