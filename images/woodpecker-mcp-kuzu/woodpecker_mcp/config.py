"""Configuration seam - env-var overridable defaults.

The graph is populated from a topology source (dependencies + health) and a
metrics source (Prometheus by default). Every variable is documented in the
repo's .env.sample and docs/CONFIGURATION.md.
"""
import os


def _load_dotenv(path=None):
    """Populate os.environ from a .env file - WP_ENV_FILE if set, else .env in
    the working directory. Values already set in the environment (e.g. the
    Holmes toolset env: block) win. Only WP_*/DD_* keys are loaded: the CWD is
    the *spawning* process's (Holmes), and a stray project .env there must not
    inject unrelated variables into this server."""
    path = path or os.environ.get("WP_ENV_FILE", ".env")
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, val = line.split("=", 1)
                key = key.strip()
                if not key.startswith(("WP_", "DD_")):
                    continue
                os.environ.setdefault(key, val.strip().strip('"').strip("'"))
    except OSError:
        pass


_load_dotenv()

# --- Graph store backend: "falkordb" (server, default) or "kuzu" (embedded) ---
GRAPH_BACKEND = os.environ.get("WP_GRAPH_BACKEND", "falkordb")

# FalkorDB connection (used when WP_GRAPH_BACKEND=falkordb).
FALKOR_HOST = os.environ.get("WP_FALKOR_HOST", "localhost")
FALKOR_PORT = int(os.environ.get("WP_FALKOR_PORT", "6379"))
FALKOR_GRAPH = os.environ.get("WP_FALKOR_GRAPH", "woodpecker")
FALKOR_PASSWORD = os.environ.get("WP_FALKOR_PASSWORD") or None

# Image `woodpecker-mcp setup` runs for FalkorDB. Point it at an internal
# registry mirror in restricted/air-gapped environments (e.g.
# registry.corp/falkordb/falkordb:<tag>).
FALKOR_IMAGE = os.environ.get("WP_FALKOR_IMAGE", "falkordb/falkordb:v4.18.11")

# Kuzu embedded DB path (used when WP_GRAPH_BACKEND=kuzu).
KUZU_PATH = os.environ.get("WP_KUZU_PATH", "./woodpecker.kuzu")

# Topology backend (the connector seam): "docker", "k8s", or "traces".
TOPOLOGY = os.environ.get("WP_TOPOLOGY", "docker")

# Docker connector (used when WP_TOPOLOGY=docker). Empty (the default) =
# discover every Docker Compose project on the host; set a name to scope the
# graph to one project.
COMPOSE_PROJECT = os.environ.get("WP_COMPOSE_PROJECT", "")

# Kubernetes connector (used when WP_TOPOLOGY=k8s). Empty context = the current
# kubeconfig context, or the in-cluster ServiceAccount when running in a pod.
K8S_NAMESPACE = os.environ.get("WP_K8S_NAMESPACE", "default")
# Multiple namespaces: comma list, or "*" for all (minus the exclusions below).
# When set, this wins over WP_K8S_NAMESPACE; with more than one namespace,
# graph nodes are namespace-qualified ("shop/web").
K8S_NAMESPACES = [s.strip() for s in os.environ.get("WP_K8S_NAMESPACES", "").split(",")
                  if s.strip()]
K8S_EXCLUDE_NAMESPACES = {s.strip() for s in os.environ.get(
    "WP_K8S_EXCLUDE_NAMESPACES",
    "kube-system,kube-public,kube-node-lease,local-path-storage").split(",") if s.strip()}
K8S_CONTEXT = os.environ.get("WP_K8S_CONTEXT", "")

# Trace connector (used when WP_TOPOLOGY=traces). Edges come from real call
# spans. Pair it with a metrics source for health - traces give structure only.
TRACES_BACKEND = os.environ.get("WP_TRACES_BACKEND", "jaeger")  # jaeger
JAEGER_URL = os.environ.get("WP_JAEGER_URL", "http://localhost:16686")
TRACES_LOOKBACK = int(os.environ.get("WP_TRACES_LOOKBACK", "3600"))  # seconds

PROM_URL = os.environ.get("WP_PROM_URL", "http://localhost:9091")

# Metric queries (PromQL). Metric names depend on how each app is instrumented,
# so override these to match your deployment. These are the only
# Prometheus-specific strings in the system - a non-Prometheus backend ignores
# them and implements MetricsSource directly.
#   ERROR_RATE_QUERY: one series per service, valued in failed-requests/sec.
#   ERROR_RATE_LABEL: the label on that series that holds the service name.
#   DB_UP_QUERY:      a single 0/1 scalar; set empty to skip the DB check.
ERROR_RATE_QUERY = os.environ.get(
    "WP_ERROR_RATE_QUERY",
    'sum(rate(http_requests_total{status="5xx"}[1m])) by (service)',
)
ERROR_RATE_LABEL = os.environ.get("WP_ERROR_RATE_LABEL", "service")
DB_UP_QUERY = os.environ.get("WP_DB_UP_QUERY", "pg_up")
# The service node the DB_UP_QUERY result attaches to (your database's name in
# the graph - "postgres", "orders-db", ...). The exporter target can be up
# while the DB itself is down; this pins that signal to the right node.
DB_SERVICE = os.environ.get("WP_DB_SERVICE", "db")

# --- Metrics backend: "prometheus" (default) or "datadog" ---
METRICS_BACKEND = os.environ.get("WP_METRICS_BACKEND", "prometheus")

# Datadog metrics source (used when WP_METRICS_BACKEND=datadog). The queries are
# Datadog's language, not PromQL. DD_SITE is the region host (datadoghq.com,
# datadoghq.eu, us3.datadoghq.com...). Keys fall back to the standard DD_* names.
DD_SITE = os.environ.get("WP_DD_SITE", "datadoghq.com")
DD_API_KEY = os.environ.get("WP_DD_API_KEY") or os.environ.get("DD_API_KEY")
DD_APP_KEY = os.environ.get("WP_DD_APP_KEY") or os.environ.get("DD_APP_KEY")
DD_ERROR_RATE_QUERY = os.environ.get(
    "WP_DD_ERROR_RATE_QUERY",
    "sum:trace.http.request.errors{*} by {service}.as_rate()",
)
DD_SERVICE_TAG = os.environ.get("WP_DD_SERVICE_TAG", "service")
DD_DB_UP_QUERY = os.environ.get("WP_DD_DB_UP_QUERY", "")  # e.g. max:postgresql.up{*}
DD_WINDOW = int(os.environ.get("WP_DD_WINDOW", "300"))  # query lookback, seconds
# Which services are "reporting to Datadog" (drives blind-spot detection). A
# hits/presence metric, NOT the error metric - a healthy service with zero
# errors emits no error series and must not read as a blind spot.
DD_PRESENCE_QUERY = os.environ.get(
    "WP_DD_PRESENCE_QUERY", "sum:trace.http.request.hits{*} by {service}.as_rate()")

# --- HTTP transport (`woodpecker-mcp serve --http`) ---
# Bind host. Loopback by default; set 0.0.0.0 only where the network path is
# protected (in-cluster behind a NetworkPolicy, or with WP_HTTP_TOKEN set).
# The Docker image sets 0.0.0.0 - pods must be reachable on the pod network.
HTTP_HOST = os.environ.get("WP_HTTP_HOST", "127.0.0.1")
# Optional bearer token. When set, every HTTP request must carry
# "Authorization: Bearer <token>"; requests without it get a 401.
HTTP_TOKEN = os.environ.get("WP_HTTP_TOKEN") or None

# When true (default), query commands/tools rebuild the graph from live sources
# first. Set WP_AUTO_REFRESH=0 to query a snapshot you ingested separately (e.g.
# a static topology you're studying offline).
AUTO_REFRESH = os.environ.get("WP_AUTO_REFRESH", "1") != "0"

# Rebuilds within this many seconds of the last one are skipped, so one
# investigation's burst of tool calls shares a single kubectl/Prometheus sweep.
# 0 = refresh on every call (the pre-cache behavior).
REFRESH_TTL = float(os.environ.get("WP_REFRESH_TTL", "10"))

# When set, every diagnose writes a timestamped JSON snapshot (diagnosis + full
# topology) into this directory - the postmortem/audit trail that survives the
# incident healing. Empty = disabled. Rotation keeps the newest SNAPSHOT_KEEP.
SNAPSHOT_DIR = os.environ.get("WP_SNAPSHOT_DIR", "")
SNAPSHOT_KEEP = int(os.environ.get("WP_SNAPSHOT_KEEP", "100"))

# Services we expect to be scraped - a monitored service with no live scrape
# target is flagged as an observability blind spot (lost visibility, not an
# outage). Empty (the default) = AUTO: expectation comes from scrape intent the
# topology declares (k8s `prometheus.io/scrape: "true"` pod annotations, docker
# labels) - the set difference of "declared" minus "actually scraped". Setting
# a comma list here overrides auto mode entirely.
MONITORED_SERVICES = set(
    filter(None, os.environ.get("WP_MONITORED_SERVICES", "").split(","))
)

# Topology memory: when set to a file path, services (and their edges) that
# vanish from live discovery - a workload deleted mid-incident, a traced
# service that stopped emitting spans - are kept in the graph as DOWN until
# unseen for WP_TOPOLOGY_MEMORY_TTL seconds, instead of silently disappearing.
TOPOLOGY_MEMORY = os.environ.get("WP_TOPOLOGY_MEMORY", "")
TOPOLOGY_MEMORY_TTL = float(os.environ.get("WP_TOPOLOGY_MEMORY_TTL", "3600"))

# A service whose 5xx rate (req/s) exceeds this is "erroring" even if its
# container reports healthy - catches functional failure container health misses.
ERROR_RATE_THRESHOLD = float(os.environ.get("WP_ERROR_RATE_THRESHOLD", "0.05"))
