"""Connector interfaces - the thin seam between the graph and where data comes
from. Implement these against your infra (Docker, Kubernetes, a CMDB, traces...)
and the graph/diagnosis logic is unchanged.

Also home to the shared inference helpers both container connectors use:
`references_host` (does this env value point at that service?) and `role_for`
(name- then image-based service role).
"""
import re
from abc import ABC, abstractmethod

# What may legally follow a hostname inside a URI/value.
_AFTER = r"(?=[:/@,\s]|$)"

# Env-var names that plausibly hold a host/endpoint. Bare values ("db",
# "db:5432") only count as references when the var name looks like this -
# otherwise MODE=db would invent an edge to the db service.
_HOSTISH_NAME = re.compile(
    r"(HOST|ADDR|ADDRESS|URL|URI|SERVER|ENDPOINT|DSN|SEED|BROKER|MASTER|PRIMARY|REPLICA)S?(_|$)", re.I)


def references_host(value, host, name=None):
    """True if env value `value` references `host` as a network host.

    Matches, without false-substring hits (host 'db' must not match
    'db_exporter') and without treating URL PATH segments as hosts (a Postgres
    database named 'orders' in postgres://user@pg:5432/orders must not create
    an edge to the 'orders' service - hosts live in the authority component,
    right after '//' or '@'):
      - URI forms:      http://db:5432, postgres://user@db/x
      - k8s service DNS: db.<ns>.svc[.cluster.local][:port]
      - bare host/port:  DB_HOST=db, DB_ADDR=db:5432, BROKERS=a:9092,b:9092
        (only when the env var `name` looks host-ish, see _HOSTISH_NAME)
    """
    if not value:
        return False
    h = re.escape(host)
    if re.search(rf"(?://|@){h}{_AFTER}", value):
        return True
    for part in value.split(","):
        if re.search(rf"(?:^|//|@){h}\.[a-z0-9-]+\.svc(\.[a-z0-9.]*)?(:\d+)?{_AFTER}",
                     part.strip()):
            return True
    if name is None or _HOSTISH_NAME.search(name):
        for part in value.split(","):
            if re.fullmatch(rf"{h}(:\d+)?", part.strip()):
                return True
    return False


# Service role: explicit name map first, then what the image name gives away.
_NAME_ROLES = {
    "db": "database", "postgres": "database", "postgresql": "database", "mysql": "database",
    "prometheus": "observability", "grafana": "observability", "db_exporter": "observability",
    "loadgen": "load-generator",
}
_IMAGE_ROLES = [
    # observability first: exporter images name the DB they export
    # (postgres-exporter must not classify as a database)
    (re.compile(r"prometheus|grafana|jaeger|otel|exporter", re.I), "observability"),
    (re.compile(r"postgres|mysql|mariadb|mongo|redis|cassandra|clickhouse|cockroach", re.I),
     "database"),
    (re.compile(r"locust|loadgen|k6\b|vegeta", re.I), "load-generator"),
]


def role_for(name, image=None):
    if name in _NAME_ROLES:
        return _NAME_ROLES[name]
    for pattern, role in _IMAGE_ROLES:
        if image and pattern.search(image):
            return role
    return "app"


class TopologySource(ABC):
    """Discovers system structure: services, their containers/instances, and the
    dependency edges between services (who calls / relies on whom)."""

    @abstractmethod
    def discover(self):
        """Return (services, containers, dep_edges).

        services:   list of {name, role}
        containers: list of {name, service, state, health, restarts, image}
        dep_edges:  list of (src_service, dst_service)  # src depends on dst
        """
        raise NotImplementedError


class MetricsSource(ABC):
    """Live telemetry the graph needs - three signals, expressed by intent so
    each backend (Prometheus, Datadog, New Relic, CloudWatch...) translates them
    into its own query language. The graph/diagnosis logic stays backend-agnostic.
    """

    @abstractmethod
    def targets(self):
        """Return list of {job, service, health, endpoint} for active scrape
        targets. Drives blind-spot / monitoring-gap detection."""
        raise NotImplementedError

    @abstractmethod
    def error_rates(self):
        """Return {service: failed-requests-per-second}. Empty dict if the
        backend cannot report it. Drives the 'erroring' status that container
        health misses (a process up but returning 5xx)."""
        raise NotImplementedError

    def db_up(self):
        """Return True/False for database liveness, or None if the backend
        cannot report it (the default). A DB process can be down while its
        metrics exporter target is still up."""
        return None
