"""MetricsSource backed by the Datadog metrics API (v1 query).

Datadog speaks its own query language, not PromQL, so this implements the
MetricsSource interface directly - proof that the seam holds for a non-Prometheus
backend. Requires WP_DD_API_KEY + WP_DD_APP_KEY. stdlib only.
"""
import json
import time
import urllib.parse
import urllib.request

from .. import config
from .base import MetricsSource


class DatadogMetricsSource(MetricsSource):
    def __init__(self, site=None, api_key=None, app_key=None, error_rate_query=None,
                 service_tag=None, db_up_query=None, window=None, presence_query=None):
        self.site = (site or config.DD_SITE).rstrip("/")
        self.api_key = api_key or config.DD_API_KEY
        self.app_key = app_key or config.DD_APP_KEY
        self.error_rate_query = error_rate_query or config.DD_ERROR_RATE_QUERY
        self.presence_query = presence_query or config.DD_PRESENCE_QUERY
        self.service_tag = service_tag or config.DD_SERVICE_TAG
        # "" disables the DB check; None means "use the configured default".
        self.db_up_query = config.DD_DB_UP_QUERY if db_up_query is None else db_up_query
        self.window = int(window or config.DD_WINDOW)

    def _query(self, q):
        now = int(time.time())
        params = {"from": now - self.window, "to": now, "query": q}
        url = f"https://api.{self.site}/api/v1/query?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={
            "DD-API-KEY": self.api_key or "",
            "DD-APPLICATION-KEY": self.app_key or "",
        })
        with urllib.request.urlopen(req, timeout=8) as r:
            return json.load(r).get("series") or []

    def _service_of(self, series):
        prefix = self.service_tag + ":"
        for tag in series.get("tag_set") or []:
            if tag.startswith(prefix):
                return tag[len(prefix):]
        for part in (series.get("scope") or "").split(","):  # e.g. "service:web,env:prod"
            part = part.strip()
            if part.startswith(prefix):
                return part[len(prefix):]
        return None

    @staticmethod
    def _last_value(series):
        for _ts, val in reversed(series.get("pointlist") or []):
            if val is not None:
                return val
        return None

    def error_rates(self):
        out = {}
        for s in self._query(self.error_rate_query):
            name = self._service_of(s)
            val = self._last_value(s)
            if name is not None and val is not None:
                out[name] = round(float(val), 3)
        return out

    def targets(self):
        # Datadog has no scrape-target list; a service emitting the PRESENCE
        # metric (hits, not errors - a healthy service has zero errors and
        # would falsely read as a blind spot) counts as "reporting".
        out = []
        for s in self._query(self.presence_query):
            name = self._service_of(s)
            if name is not None:
                out.append({"job": name, "service": name, "health": "up", "endpoint": "datadog"})
        return out

    def db_up(self):
        if not self.db_up_query:
            return None
        series = self._query(self.db_up_query)
        if not series:
            return None
        val = self._last_value(series[0])
        return None if val is None else float(val) >= 1
