#!/usr/bin/env python3
"""Personalized home.keiretsu.top — auto-discovers the user's apps by querying
the Kubernetes API for SecurityPolicies containing their email, then resolves
the referenced HTTPRoutes and reads Homer annotations for display."""

import json
import os
import ssl
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# ── K8s API client (stdlib only, no kubernetes client dep) ───────────────────

K8S_TOKEN_PATH = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")
K8S_CA_PATH = Path("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
K8S_HOST = "https://kubernetes.default.svc"
STYLE_PATH = Path("/etc/homepage/style.css")
GARAGE_PAGE_PATH = Path("/etc/homepage/garage.html")
CACHE_TTL = 300  # seconds — re-list SecurityPolicies every 5 minutes

# ── Mimir / Prometheus client (stdlib only) ──────────────────────────────────

MIMIR_HOST = os.environ.get(
    "MIMIR_HOST",
    "http://mimir-gateway.mimir.svc.cluster.local:8080/prometheus",
)
MIMIR_TENANTS = ["talos-ottawa", "talos-robbinsdale", "talos-stpetersburg"]

DISCOVERY_CACHE = {"data": None, "expires_at": 0}
GARAGE_METRICS_CACHE = {"data": None, "expires_at": 0}
GARAGE_METRICS_CACHE_TTL = 8  # seconds — brief cache to reduce Mimir QPS


def k8s_api(path):
    """Make an authenticated GET request to the K8s API."""
    token = K8S_TOKEN_PATH.read_text()
    req = urllib.request.Request(f"{K8S_HOST}{path}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    ctx = ssl.create_default_context(cafile=K8S_CA_PATH)
    with urllib.request.urlopen(req, context=ctx) as resp:
        return json.loads(resp.read().decode())


def load_style():
    if STYLE_PATH.exists():
        return STYLE_PATH.read_text()
    return ""


def load_garage_page():
    if GARAGE_PAGE_PATH.exists():
        return GARAGE_PAGE_PATH.read_text()
    return None


# ── Mimir query helper ───────────────────────────────────────────────────────


def mimir_query(query, tenant):
    """Query Mimir (Prometheus) and return the result vector, or None on error."""
    url = f"{MIMIR_HOST}/api/v1/query?query={urllib.parse.quote(query)}"
    req = urllib.request.Request(url)
    req.add_header("X-Scope-OrgID", tenant)
    req.add_header("Accept", "application/json")
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            return data.get("data", {}).get("result", [])
    except Exception:
        return None


def mimir_query_range(query, tenant, duration="1h", step="5m"):
    """Query Mimir range vector and return list of (timestamp, value) pairs."""
    now = time.time()
    start = now - _parse_duration(duration)
    url = (
        f"{MIMIR_HOST}/api/v1/query_range"
        f"?query={urllib.parse.quote(query)}"
        f"&start={start}&end={now}&step={step}"
    )
    req = urllib.request.Request(url)
    req.add_header("X-Scope-OrgID", tenant)
    req.add_header("Accept", "application/json")
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            return data.get("data", {}).get("result", [])
    except Exception:
        return None


def _parse_duration(d):
    unit = d[-1]
    val = int(d[:-1])
    multipliers = {"h": 3600, "m": 60, "s": 1, "d": 86400}
    return val * multipliers.get(unit, 3600)


def fetch_garage_metrics():
    """Fetch all Garage metrics needed for the /garage page as a JSON dict.

    All 22 Mimir queries are run in parallel via ThreadPoolExecutor (stdlib).
    Results are cached briefly (GARAGE_METRICS_CACHE_TTL seconds) to reduce
    Mimir QPS on rapid page refreshes.
    """
    now = time.time()

    # Return stale cache if still fresh — cheap reduction in Mimir QPS
    if GARAGE_METRICS_CACHE["data"] and now < GARAGE_METRICS_CACHE["expires_at"]:
        return GARAGE_METRICS_CACHE["data"]

    queries = [
        ("bucket_bytes", "sum(garage_bucket_bytes)", "talos-ottawa"),
        ("bucket_objects", "sum(garage_bucket_objects)", "talos-ottawa"),
        ("layout_version", "garage_layout_current_version", "talos-ottawa"),
        ("queue_length", "max(garage_worker_queue_length)", "talos-ottawa"),
        ("block_errors", "sum(garage_node_block_errors)", "talos-ottawa"),
        ("replication_factor", "garage_replication_factor", "talos-ottawa"),
        ("nodes_ottawa", "count(kube_node_info)", "talos-ottawa"),
        ("nodes_robbinsdale", "count(kube_node_info)", "talos-robbinsdale"),
        ("nodes_stpetersburg", "count(kube_node_info)", "talos-stpetersburg"),
        ("garage_nodes_ottawa",
         "count(garage_local_disk_avail{volume='data'})", "talos-ottawa"),
        ("garage_nodes_robbinsdale",
         "count(garage_local_disk_avail{volume='data'})", "talos-robbinsdale"),
        ("garage_nodes_stpetersburg",
         "count(garage_local_disk_avail{volume='data'})", "talos-stpetersburg"),
        ("disk_total_ottawa",
         "sum(garage_local_disk_total{volume='data'})", "talos-ottawa"),
        ("disk_avail_ottawa",
         "sum(garage_local_disk_avail{volume='data'})", "talos-ottawa"),
        ("disk_total_robbinsdale",
         "sum(garage_local_disk_total{volume='data'})", "talos-robbinsdale"),
        ("disk_avail_robbinsdale",
         "sum(garage_local_disk_avail{volume='data'})", "talos-robbinsdale"),
        ("disk_total_stpetersburg",
         "sum(garage_local_disk_total{volume='data'})", "talos-stpetersburg"),
        ("disk_avail_stpetersburg",
         "sum(garage_local_disk_avail{volume='data'})", "talos-stpetersburg"),
        ("healthy_ottawa",
         "count(kube_node_status_condition{condition='Ready',status='true'})",
         "talos-ottawa"),
        ("healthy_robbinsdale",
         "count(kube_node_status_condition{condition='Ready',status='true'})",
         "talos-robbinsdale"),
        ("healthy_stpetersburg",
         "count(kube_node_status_condition{condition='Ready',status='true'})",
         "talos-stpetersburg"),
        ("ingress_ottawa",
         "count(kube_pod_status_phase{phase='Running',namespace='tailscale',pod=~'common-ingress.*'})",
         "talos-ottawa"),
        ("ingress_robbinsdale",
         "count(kube_pod_status_phase{phase='Running',namespace='tailscale',pod=~'common-ingress.*'})",
         "talos-robbinsdale"),
        ("ingress_stpetersburg",
         "count(kube_pod_status_phase{phase='Running',namespace='tailscale',pod=~'common-ingress.*'})",
         "talos-stpetersburg"),
        ("egress_ottawa",
         "count(kube_pod_status_phase{phase='Running',namespace='tailscale',pod=~'common-egress.*'})",
         "talos-ottawa"),
        ("egress_robbinsdale",
         "count(kube_pod_status_phase{phase='Running',namespace='tailscale',pod=~'common-egress.*'})",
         "talos-robbinsdale"),
        ("egress_stpetersburg",
         "count(kube_pod_status_phase{phase='Running',namespace='tailscale',pod=~'common-egress.*'})",
         "talos-stpetersburg"),
    ]

    metrics = {}

    with ThreadPoolExecutor(max_workers=min(len(queries), 22)) as pool:
        future_map = {
            pool.submit(mimir_query, query, tenant): key
            for key, query, tenant in queries
        }
        for future in as_completed(future_map):
            key = future_map[future]
            try:
                result = future.result()
            except Exception:
                result = None

            if result is None:
                metrics[key] = None if key == "layout_version" else 0.0
            elif key == "layout_version":
                try:
                    metrics[key] = str(result[0]["value"][1]) if result else None
                except (KeyError, IndexError, TypeError):
                    metrics[key] = None
            else:
                try:
                    metrics[key] = float(result[0]["value"][1]) if result else 0.0
                except (ValueError, KeyError, IndexError, TypeError):
                    metrics[key] = 0.0

    # Cache the result (even if partial) so rapid page refreshes hit the cache
    GARAGE_METRICS_CACHE["data"] = metrics
    GARAGE_METRICS_CACHE["expires_at"] = now + GARAGE_METRICS_CACHE_TTL
    return metrics


# ── Time-series garage metrics ─────────────────────────────────────────────

GARAGE_TS_CACHE = {"data": None, "expires_at": 0}
GARAGE_TS_CACHE_TTL = 60  # seconds — time-series data is larger, cache longer


def fetch_garage_ts_metrics():
    """Fetch time-series garage metrics for live graphs.

    Runs ~10 PromQL range queries in parallel across the ottawa tenant.
    Cached for 60s.
    Returns a dict of key -> [[timestamp, value], ...].
    """
    now = time.time()
    if GARAGE_TS_CACHE["data"] and now < GARAGE_TS_CACHE["expires_at"]:
        return GARAGE_TS_CACHE["data"]

    queries = [
        ("s3_requests",
         "sum by (api_endpoint) (rate(api_s3_request_counter[5m]))",
         "talos-ottawa"),
        ("block_bytes_read",
         "sum(rate(block_bytes_read[5m]))",
         "talos-ottawa"),
        ("block_bytes_written",
         "sum(rate(block_bytes_written[5m]))",
         "talos-ottawa"),
        ("resync_queue",
         "max(block_resync_queue_length)",
         "talos-ottawa"),
        ("resync_errored",
         "max(block_resync_errored_blocks)",
         "talos-ottawa"),
        ("resync_recv_rate",
         "sum(rate(block_resync_recv_counter[5m]))",
         "talos-ottawa"),
        ("resync_send_rate",
         "sum(rate(block_resync_send_counter[5m]))",
         "talos-ottawa"),
        ("block_errors",
         "sum(garage_node_block_errors)",
         "talos-ottawa"),
        ("worker_queue",
         "max(garage_worker_queue_length)",
         "talos-ottawa"),
        ("disk_usage_pct",
         "(1 - sum(garage_local_disk_avail{volume='data'}) / sum(garage_local_disk_total{volume='data'})) * 100",
         "talos-ottawa"),
    ]

    ts_data = {}

    with ThreadPoolExecutor(max_workers=min(len(queries), 12)) as pool:
        future_map = {
            pool.submit(mimir_query_range, q, tenant): key
            for key, q, tenant in queries
        }
        for future in as_completed(future_map):
            key = future_map[future]
            try:
                result = future.result()
            except Exception:
                result = None

            if not result:
                ts_data[key] = []
                continue

            # Merge all series for the same key into one timeline
            merged = {}
            for series in result:
                for ts, val in series.get("values", []):
                    try:
                        v = float(val)
                    except (ValueError, TypeError):
                        continue
                    if ts not in merged:
                        merged[ts] = 0.0
                    merged[ts] += v

            # Sort by timestamp and produce [[ts, val], ...] arrays
            sorted_ts = sorted(merged.keys())
            ts_data[key] = [[t, merged[t]] for t in sorted_ts]

    GARAGE_TS_CACHE["data"] = ts_data
    GARAGE_TS_CACHE["expires_at"] = now + GARAGE_TS_CACHE_TTL
    return ts_data


def render_garage_page(template, metrics):
    """Replace METRICS_PLACEHOLDER in the garage template with live metric data."""
    json_str = json.dumps(metrics)
    replacement = f"const METRICS_DATA = {json_str};"
    return template.replace("/* METRICS_PLACEHOLDER */", replacement, 1)


# ── App discovery from K8s API ────────────────────────────────────────────────

ANNOTATION_PREFIX = "item.homer.rajsingh.info/"
SERVICE_ANNOTATION_PREFIX = "service.homer.rajsingh.info/"
HIDE_ANNOTATION = ANNOTATION_PREFIX + "hide"

GATEWAY_ICONS = {
    "public": "🌐",
    "private": "🔒",
    "ts": "🔗",
}

GATEWAY_NAMES = {
    "public": "Public",
    "private": "Private",
    "ts": "Tailscale",
}

KNOWN_GROUP_ICONS = {
    "Agents": "🤖",
    "Infrastructure": "⚙️",
    "Media": "🎬",
    "Home": "🏠",
    "Utilities": "🛠️",
    "Monitoring": "📊",
    "Development": "💻",
    "Security": "🔐",
    "Storage": "💾",
    "Sandbox": "🧪",
    "Other": "📌",
}

# Group ordering — lower number = higher on the page
GROUP_ORDER = {
    "Home": 0,
    "Media": 1,
    "Infrastructure": 2,
    "Development": 3,
    "Monitoring": 4,
    "Security": 5,
    "Storage": 6,
    "Utilities": 7,
    "Agents": 8,
    "Sandbox": 9,
    "Public": 10,
    "Other": 11,
}

# Hostname prefixes that are test/dev routes — hidden entirely
HIDE_HOSTNAME_PATTERNS = (
    "-hello",
    "workspace-test",
    "opencode",
    "kubernetes-manifests-hello",
    "kubernetes-manifests-opencode",
)

# Curated metadata for services that lack Homer annotations.
# Keyed by the hostname prefix (first label of the hostname).
# Values override the fallback derivation.
KNOWN_SERVICES = {
    "forgejo": {
        "name": "Forgejo",
        "subtitle": "Git Forge",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/forgejo.svg",
        "group": "Development",
    },
    "gatus": {
        "name": "Gatus",
        "subtitle": "Status & Monitoring",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/gatus.svg",
        "group": "Monitoring",
    },
    "grafana": {
        "name": "Grafana",
        "subtitle": "Analytics & Monitoring",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/grafana.svg",
        "group": "Monitoring",
    },
    "kener": {
        "name": "Kener",
        "subtitle": "Public Status Page",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/kener.svg",
        "group": "Monitoring",
    },
    "hubble": {
        "name": "Hubble UI",
        "subtitle": "Network Observability",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/cilium.svg",
        "group": "Monitoring",
    },
    "woodpecker": {
        "name": "Woodpecker CI",
        "subtitle": "CI/CD",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/woodpecker-ci.svg",
        "group": "Development",
    },
    "zot": {
        "name": "Zot Registry",
        "subtitle": "OCI Container Registry",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/harbor.svg",
        "group": "Infrastructure",
    },
    "velero": {
        "name": "Velero",
        "subtitle": "Backups & Recovery",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/velero.svg",
        "group": "Infrastructure",
    },
    "teslamate": {
        "name": "TeslaMate",
        "subtitle": "Tesla Data Logger",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/teslamate.svg",
        "group": "Other",
    },
    "qbittorrent": {
        "name": "qBittorrent",
        "subtitle": "Download Client",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/qbittorrent.svg",
        "group": "Media",
    },
    "kromgo": {
        "name": "Kromgo",
        "subtitle": "Public Status Badges",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/kubernetes.svg",
        "group": "Monitoring",
    },
    "kener": {
        "name": "Kener",
        "subtitle": "Public Status Page",
        "logo": "",
        "icon": "📊",
        "group": "Monitoring",
    },
    "tinyauth": {
        "name": "TinyAuth",
        "subtitle": "Authentication Gateway",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/tinyauth.svg",
        "group": "Security",
    },
    "auth": {
        "name": "TinyAuth",
        "subtitle": "Authentication Gateway",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/tinyauth.svg",
        "group": "Security",
    },
    "s3": {
        "name": "Garage S3",
        "subtitle": "Object Storage",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/garage.svg",
        "group": "Storage",
    },
    "keiretsu": {
        "name": "Keiretsu Web",
        "subtitle": "Static Website",
        "logo": "",
        "icon": "🌐",
        "group": "Other",
    },
    "trades": {
        "name": "Trades",
        "subtitle": "Trading Dashboard",
        "logo": "",
        "icon": "📈",
        "group": "Other",
    },
    "status": {
        "name": "Status",
        "subtitle": "Service Status",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/gatus.svg",
        "group": "Monitoring",
    },
    "home": {
        "_hide": True,
    },
    # Agent web UIs — use openai.svg as a generic AI icon
    "raj": {
        "name": "Raj Assistant",
        "subtitle": "AI Assistant Web",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/openai.svg",
        "group": "Agents",
    },
    "abtar": {
        "name": "Abtar",
        "subtitle": "AI Assistant Web",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/openai.svg",
        "group": "Agents",
    },
    "teaspoon": {
        "name": "Teaspoon",
        "subtitle": "AI Assistant Web",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/openai.svg",
        "group": "Agents",
    },
    "bhaiya": {
        "name": "Bhaiya",
        "subtitle": "Sandbox Control Plane",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/openai.svg",
        "group": "Agents",
    },
    "kartik": {
        "name": "Kartik Assistant",
        "subtitle": "AI Assistant Web",
        "logo": "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/svg/openai.svg",
        "group": "Agents",
    },
}


def discover_routes():
    """List all SecurityPolicies and HTTPRoutes once and return structured
    data for per-user filtering. Cached globally (CACHE_TTL) since the K8s
    state is identical for all users — only the email filter differs."""
    now = time.time()
    if DISCOVERY_CACHE["data"] and now < DISCOVERY_CACHE["expires_at"]:
        return DISCOVERY_CACHE["data"]

    # 1. List ALL SecurityPolicies across all namespaces
    try:
        sp_list = k8s_api("/apis/gateway.envoyproxy.io/v1alpha1/securitypolicies")
    except Exception as e:
        if DISCOVERY_CACHE["data"]:
            return DISCOVERY_CACHE["data"]  # stale cache better than nothing
        return {"error": f"cannot list SecurityPolicies: {e}"}

    # Build:
    #   auth_map:    (ns, route_name) -> set of lowercased emails authorized
    #   restricted:  set of (ns, route_name) gated by a Deny-by-default policy
    auth_map = {}
    restricted = set()
    for sp in sp_list.get("items", []):
        sp_ns = sp.get("metadata", {}).get("namespace", "")
        authz = sp.get("spec", {}).get("authorization", {})
        default_action = authz.get("defaultAction", "")
        rules = authz.get("rules", [])

        authorized_emails = set()
        for rule in rules:
            if rule.get("action") != "Allow":
                continue
            for header in rule.get("principal", {}).get("headers", []):
                if header.get("name", "").lower() == "remote-email":
                    authorized_emails.update(
                        v.lower() for v in header.get("values", [])
                    )

        for ref in sp.get("spec", {}).get("targetRefs", []):
            route_name = ref.get("name", "")
            if not route_name:
                continue
            ref_ns = ref.get("namespace", sp_ns)
            key = (ref_ns, route_name)
            if authorized_emails:
                auth_map.setdefault(key, set()).update(authorized_emails)
            if default_action == "Deny":
                restricted.add(key)

    # 2. List ALL HTTPRoutes across all namespaces (one call, not N)
    try:
        route_list = k8s_api("/apis/gateway.networking.k8s.io/v1/httproutes")
    except Exception as e:
        if DISCOVERY_CACHE["data"]:
            return DISCOVERY_CACHE["data"]
        return {"error": f"cannot list HTTPRoutes: {e}"}

    all_routes = {}
    public_keys = []
    for route in route_list.get("items", []):
        meta = route.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        annotations = meta.get("annotations", {}) or {}
        spec = route.get("spec", {})

        if annotations.get(HIDE_ANNOTATION, "").lower() == "true":
            continue

        hostname = ""
        for host in spec.get("hostnames", []):
            hostname = host
            break

        # Hide test/dev routes by hostname pattern
        hostname_lower = hostname.lower()
        if any(p in hostname_lower for p in HIDE_HOSTNAME_PATTERNS):
            continue

        # Hide routes flagged in the curated registry
        host_prefix = hostname.split(".")[0].lower() if hostname else ""
        curated = KNOWN_SERVICES.get(host_prefix, {})
        if curated.get("_hide"):
            continue

        parent_gateways = [
            ref.get("name", "") for ref in spec.get("parentRefs", [])
        ]

        key = (ns, name)
        all_routes[key] = {
            "name": name,
            "hostname": hostname,
            "annotations": annotations,
            "parent_gateways": parent_gateways,
        }

        # A route is "public" (available to everyone) if it attaches to the
        # public gateway and is NOT gated by a Deny-by-default SecurityPolicy.
        if "public" in parent_gateways and key not in restricted:
            public_keys.append(key)

    result = {
        "all_routes": all_routes,
        "auth_map": auth_map,
        "public_keys": public_keys,
    }
    DISCOVERY_CACHE["data"] = result
    DISCOVERY_CACHE["expires_at"] = now + CACHE_TTL
    return result


def build_app_item(route_info):
    """Convert a raw route info dict into a display item.

    Priority: Homer annotations > curated KNOWN_SERVICES registry > heuristics.
    """
    annotations = route_info["annotations"]
    hostname = route_info["hostname"]
    name = route_info["name"]
    parent_gateways = route_info["parent_gateways"]

    host_prefix = hostname.split(".")[0].lower() if hostname else ""
    curated = KNOWN_SERVICES.get(host_prefix, {})

    # Display name: annotation > curated > hostname-derived
    display_name = (
        annotations.get(ANNOTATION_PREFIX + "name", "")
        or curated.get("name", "")
    )
    subtitle = (
        annotations.get(ANNOTATION_PREFIX + "subtitle", "")
        or curated.get("subtitle", "")
    )
    logo = (
        annotations.get(ANNOTATION_PREFIX + "logo", "")
        or curated.get("logo", "")
    )
    keywords = annotations.get(ANNOTATION_PREFIX + "keywords", "")

    # Group: annotation > curated > gateway-name fallback
    group = (
        annotations.get(SERVICE_ANNOTATION_PREFIX + "name", "")
        or curated.get("group", "")
    )
    group_icon = annotations.get(SERVICE_ANNOTATION_PREFIX + "icon", "")

    if not group:
        for gw in parent_gateways:
            if gw in GATEWAY_NAMES:
                group = GATEWAY_NAMES[gw]
                break
        if not group:
            group = "Other"

    if not group_icon:
        group_icon = KNOWN_GROUP_ICONS.get(group, "\U0001F4CC")

    # Derive display name from hostname if still empty
    if not display_name and hostname:
        display_name = prettify_hostname(hostname)

    # Determine icon: curated emoji > gateway-based emoji
    if not logo:
        icon = curated.get("icon") or GATEWAY_ICONS.get(
            next(
                (gw for gw in parent_gateways if gw in GATEWAY_ICONS),
                "",
            ),
            "\U0001F517",
        )
    else:
        icon = None

    return {
        "name": display_name or hostname or name,
        "url": f"https://{hostname}/" if hostname else "",
        "subtitle": subtitle,
        "logo": logo,
        "icon": icon,
        "keywords": keywords,
        "group": group,
        "group_icon": group_icon,
    }


def prettify_hostname(hostname):
    """Convert a hostname like 'qbittorrent.ottawa.keiretsu.top' → 'Qbittorrent'.
    Handles hyphens and common acronyms."""
    prefix = hostname.split(".")[0]
    # Title-case each hyphen-separated word
    parts = prefix.split("-")
    # Known acronyms to uppercase
    acronyms = {"ai", "ui", "api", "cdn", "s3", "ts", "k8s", "qa", "ci", "id"}
    pretty_parts = []
    for part in parts:
        if part.lower() in acronyms:
            pretty_parts.append(part.upper())
        else:
            pretty_parts.append(part.capitalize())
    return " ".join(pretty_parts)


def discover_user_apps(email):
    """Build the list of apps visible to this user: all public routes (no
    auth required) plus any routes the user is specifically authorized for."""
    data = discover_routes()
    if "error" in data:
        return data

    email_lower = email.lower()
    auth_map = data["auth_map"]
    all_routes = data["all_routes"]

    # Visible routes = public (everyone) + authorized (this user)
    visible_keys = set(data["public_keys"])
    for key, emails in auth_map.items():
        if email_lower in emails:
            visible_keys.add(key)

    # Build display items
    apps = {}
    for key in visible_keys:
        route_info = all_routes.get(key)
        if route_info is None:
            continue
        apps[f"{key[0]}/{key[1]}"] = build_app_item(route_info)

    # Organize by service group
    grouped = {}
    for key, item in apps.items():
        g = item["group"]
        if g not in grouped:
            grouped[g] = {
                "name": g,
                "icon": item["group_icon"],
                "items": [],
            }
        grouped[g]["items"].append(item)

    # Sort items within each group alphabetically by display name
    for g in grouped:
        grouped[g]["items"].sort(key=lambda i: i["name"].lower())

    # Sort groups by defined order, then alphabetically for unknowns
    def group_sort_key(name):
        return (GROUP_ORDER.get(name, 99), name)

    return {"groups": [grouped[g] for g in sorted(grouped.keys(), key=group_sort_key)]}


# ── HTML rendering ────────────────────────────────────────────────────────────

HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>keiretsu home</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>\U0001F3E0</text></svg>">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@6.5.1/css/all.min.css">
  <style>{style}</style>
</head>
<body>
"""

FOOT = """</body></html>"""


def render_greeting(name):
    return (
        f'<section class="card greeting">'
        f'<h1>\U0001F44B hey {name}</h1>'
        f'<p class="subtitle">keiretsu cloud</p>'
        f'</section>'
    )


def render_icon(icon_value, logo_url=None, css_class="link-icon"):
    """Render an icon as either an <img> (logo URL), <i> (FontAwesome classes),
    or <span> (emoji)."""
    if logo_url:
        return f'<img class="link-logo" src="{logo_url}" alt="" loading="lazy">'
    if not icon_value:
        return f'<span class="{css_class}">\U0001F517</span>'
    # FontAwesome classes: "fas fa-home", "fab fa-github", etc.
    if icon_value.startswith(("fas ", "far ", "fab ", "fa-")):
        return f'<i class="{icon_value} {css_class}"></i>'
    # Emoji or text
    return f'<span class="{css_class}">{icon_value}</span>'


def render_group_section(group):
    items = group.get("items", [])
    items_html = ""
    for item in items:
        logo_html = render_icon(item.get("icon"), item.get("logo"))

        subtitle_html = (
            f'<span class="link-subtitle">{item["subtitle"]}</span>'
            if item["subtitle"]
            else ""
        )

        items_html += (
            f'<a href="{item["url"]}" class="link-card" target="_blank" rel="noopener">'
            f'{logo_html}'
            f'<span class="link-text">'
            f'<span class="link-label">{item["name"]}</span>'
            f'{subtitle_html}'
            f'</span>'
            f'</a>'
        )

    icon = group.get("icon", "\U0001F4CC")
    count = len(items)
    icon_html = render_icon(icon, css_class="group-emoji")
    return (
        f'<section class="card">'
        f'<h2>{icon_html} {group["name"]} '
        f'<span class="group-count">{count}</span></h2>'
        f'<div class="link-grid">{items_html}</div>'
        f'</section>'
    )


def render_page(user_email, display_name, groups_data, style):
    body = render_greeting(display_name or user_email)

    if "error" in groups_data:
        body += f'<section class="card"><p class="error">{groups_data["error"]}</p></section>'
    else:
        for group in groups_data.get("groups", []):
            if group.get("items"):
                body += render_group_section(group)

    return HEAD.format(style=style) + body + FOOT


# ── HTTP handler ──────────────────────────────────────────────────────────────


class HomepageHandler(BaseHTTPRequestHandler):
    style = ""
    garage_template = None

    def do_GET(self):
        if self.path == "/garage":
            self.handle_garage()
        elif self.path == "/garage/api/metrics/timeseries":
            self.handle_garage_timeseries()
        elif self.path != "/":
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
        else:
            self.handle_home()

    def handle_home(self):
        email = self.headers.get("Remote-Email", "").strip().lower()
        name = self.headers.get("Remote-Name", "").strip()

        # Skip discovery for probes or unauthenticated requests
        if not email:
            groups_data = {"groups": []}
        else:
            groups_data = discover_user_apps(email)
        html = render_page(email, name, groups_data, self.style)

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def handle_garage(self):
        template = self.garage_template
        if template is None:
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Garage page not available")
            return

        try:
            metrics = fetch_garage_metrics()
        except Exception:
            metrics = {}

        html = render_garage_page(template, metrics)

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def handle_garage_timeseries(self):
        try:
            ts_data = fetch_garage_ts_metrics()
        except Exception:
            ts_data = {}

        body = json.dumps(ts_data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    HomepageHandler.style = load_style()
    HomepageHandler.garage_template = load_garage_page()
    port = int(os.environ.get("PORT", "8080"))
    server = HTTPServer(("0.0.0.0", port), HomepageHandler)
    print(f"homepage server listening on :{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
