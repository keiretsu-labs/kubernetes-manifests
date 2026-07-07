"""MCP server: graph-backed tools over stdio or HTTP.

Each query tool rebuilds the graph from live sources first (WP_AUTO_REFRESH=1,
default), then answers from Cypher. Rebuilds within WP_REFRESH_TTL seconds of
the last one are skipped, so the ~5 tool calls of one investigation share a
single kubectl/Prometheus sweep. Set WP_AUTO_REFRESH=0 to query a snapshot
ingested separately.
"""
import threading
import time

from mcp.server.fastmcp import FastMCP

from . import build, config, snapshot
from .diagnose import diagnose as _diagnose
from .store import open_store

mcp = FastMCP("woodpecker-graph")

_store = None
_store_lock = threading.Lock()
_refresh_lock = threading.Lock()
_last_refresh = None    # time.monotonic() of the last successful refresh
_last_warnings = []


def store():
    global _store
    if _store is None:
        with _store_lock:
            if _store is None:
                _store = open_store()
    return _store


def _ready():
    """Rebuild from live sources if enabled. Returns (error_dict_or_None,
    warnings): error on connector failure, warnings for health signals that
    could not be collected (degraded, not fatal). Serialized: concurrent tool
    calls wait for the in-flight refresh, then hit the TTL cache instead of
    launching their own kubectl/Prometheus sweep."""
    global _last_refresh, _last_warnings
    if not config.AUTO_REFRESH:
        return None, []
    with _refresh_lock:
        if (_last_refresh is not None and config.REFRESH_TTL > 0
                and time.monotonic() - _last_refresh < config.REFRESH_TTL):
            return None, _last_warnings
        try:
            _last_warnings = build.refresh(store())
            _last_refresh = time.monotonic()
            return None, _last_warnings
        except Exception as e:
            _last_refresh = None
            return {"error": f"could not refresh graph from sources: {e}"}, []


def _with_warnings(out, warnings):
    if warnings:
        out["warnings"] = warnings
    return out


@mcp.tool()
def woodpecker_get_topology() -> dict:
    """Return the materialized service dependency graph: every service, its
    current status, and the services it depends on. Call first to establish the
    causal structure before diagnosing. status in {healthy, erroring, unhealthy,
    restarting, hung, down}; monitoring='MISSING' flags a possible blind spot."""
    err, warnings = _ready()
    return err or _with_warnings({"services": store().topology()}, warnings)


@mcp.tool()
def woodpecker_diagnose_root_cause() -> dict:
    """Localize the ROOT CAUSE deterministically: the DEEPEST failing service,
    the unhealthy one whose own dependencies are all healthy. Everything
    unhealthy above it is cascading fallout. Returns root cause(s), the causal
    chain per cascading symptom, blast radius, blind spots, and a page/no-page
    verdict, distinguishing a real outage from an observability blind spot
    (metrics missing but the service responds). Exact and repeatable, unlike
    per-investigation inference."""
    err, warnings = _ready()
    return err or snapshot.maybe_save(_diagnose(store(), warnings=warnings), store())


@mcp.tool()
def woodpecker_get_blast_radius(service: str, direction: str = "upstream") -> dict:
    """Transitive dependency closure of a service over DEPENDS_ON edges.
    direction='upstream': services that transitively depend on this one (its
    blast radius if it fails). direction='downstream': everything it relies on
    (trace toward a deeper root cause)."""
    if direction not in ("upstream", "downstream"):
        return {"error": "direction must be 'upstream' or 'downstream'"}
    err, warnings = _ready()
    if err:
        return err
    if not store().has_service(service):
        return {"error": f"unknown service: {service}"}
    return _with_warnings({"service": service, "direction": direction,
                           "related": store().blast_radius(service, direction)}, warnings)


@mcp.tool()
def woodpecker_get_service_health(service: str) -> dict:
    """Detailed health snapshot for one service: status, container state/health,
    restarts, 5xx error rate, db pg_up, scrape health, and blind-spot flag."""
    err, warnings = _ready()
    if err:
        return err
    h = store().service_health(service)
    if not h:
        return {"error": f"unknown service: {service}"}
    return _with_warnings(h, warnings)


@mcp.tool()
def woodpecker_detect_blind_spots() -> dict:
    """List observability blind spots: services that are healthy but have no live
    Prometheus scrape target (lost visibility, NOT an outage - do not page)."""
    err, warnings = _ready()
    return err or _with_warnings({
        "blind_spots": store().blind_spots(),
        "note": "blind spots = lost monitoring, not outages; do not page on these",
    }, warnings)


def _bearer_auth(app, token):
    """Minimal ASGI wrapper: every HTTP request must carry
    'Authorization: Bearer <token>' or gets a 401. Compares raw bytes -
    compare_digest on str raises TypeError for non-ASCII, and the header
    is attacker-controlled."""
    import hmac
    expected = f"Bearer {token}".encode()

    async def wrapped(scope, receive, send):
        if scope["type"] == "http":
            auth = next((v for k, v in scope.get("headers", [])
                         if k == b"authorization"), b"")
            if not hmac.compare_digest(auth, expected):
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"application/json"),
                                        (b"www-authenticate", b"Bearer")]})
                await send({"type": "http.response.body", "body": b'{"error": "unauthorized"}'})
                return
        await app(scope, receive, send)

    return wrapped


def run(transport="stdio", host=None, port=8000):
    if transport in ("http", "streamable-http"):
        host = host or config.HTTP_HOST
        if config.HTTP_TOKEN:
            import uvicorn
            uvicorn.run(_bearer_auth(mcp.streamable_http_app(), config.HTTP_TOKEN),
                        host=host, port=port)
            return
        if host not in ("127.0.0.1", "localhost", "::1"):
            import sys
            print(f"warning: HTTP transport bound to {host} with no WP_HTTP_TOKEN - "
                  "anyone who can reach the port can query the graph and trigger "
                  "refreshes. Set WP_HTTP_TOKEN or keep the bind loopback/cluster-internal.",
                  file=sys.stderr)
        mcp.settings.host = host
        mcp.settings.port = port
        mcp.run(transport="streamable-http")
    else:
        mcp.run(transport="stdio")
