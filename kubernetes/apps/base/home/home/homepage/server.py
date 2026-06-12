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


def fetch_garage_metrics():
    """Fetch all Garage metrics needed for the /garage page as a JSON dict."""
    metrics = {}
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
    ]
    for key, query, tenant in queries:
        result = mimir_query(query, tenant)
        if result is None:
            metrics[key] = None
        elif key == "layout_version":
            metrics[key] = result[0]["value"][1] if result else None
        else:
            metrics[key] = float(result[0]["value"][1]) if result else 0.0
    return metrics


def render_garage_page(template, metrics):
    """Replace METRICS_PLACEHOLDER in the garage template with live metric data."""
    json_str = json.dumps(metrics)
    replacement = f"const METRICS_DATA = {json_str};"
    return template.replace("/* METRICS_PLACEHOLDER */", replacement, 1)


# ── App discovery from K8s API ────────────────────────────────────────────────

ANNOTATION_PREFIX = "item.homer.rajsingh.info/"
SERVICE_ANNOTATION_PREFIX = "service.homer.rajsingh.info/"
HIDE_ANNOTATION = ANNOTATION_PREFIX + "hide"

# Icon mapping by gateway name for fallback when no Homer annotations exist
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
    "Other": "📌",
}


def discover_user_apps(email):
    """Query K8s API for all SecurityPolicies + HTTPRoutes the user can reach."""
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

    email_lower = email.lower()

    # 2. Filter SecurityPolicies that match the user's email
    matching = {}
    for sp in sp_list.get("items", []):
        sp_ns = sp.get("metadata", {}).get("namespace", "")
        rules = (
            sp.get("spec", {})
            .get("authorization", {})
            .get("rules", [])
        )
        user_emails = set()
        for rule in rules:
            if rule.get("action") != "Allow":
                continue
            for header in rule.get("principal", {}).get("headers", []):
                if header.get("name", "").lower() == "remote-email":
                    user_emails.update(v.lower() for v in header.get("values", []))

        if email_lower in user_emails:
            for ref in sp.get("spec", {}).get("targetRefs", []):
                route_name = ref.get("name", "")
                if route_name:
                    # Key by namespace + name to handle same-named routes
                    matching[(sp_ns, route_name)] = sp_ns

    # 3. Fetch each matching HTTPRoute and extract display info
    apps = {}
    for (ns, name), sp_ns in matching.items():
        try:
            route = k8s_api(
                f"/apis/gateway.networking.k8s.io/v1/namespaces/{ns}/httproutes/{name}"
            )
        except Exception:
            # Route might be in a different namespace or not exist
            continue

        meta = route.get("metadata", {})
        annotations = meta.get("annotations", {})
        spec = route.get("spec", {})

        # Skip routes explicitly hidden from dashboards
        if annotations.get(HIDE_ANNOTATION, "").lower() == "true":
            continue

        hostname = ""
        for host in spec.get("hostnames", []):
            hostname = host
            break

        display_name = annotations.get(ANNOTATION_PREFIX + "name", "")
        subtitle = annotations.get(ANNOTATION_PREFIX + "subtitle", "")
        logo = annotations.get(ANNOTATION_PREFIX + "logo", "")
        keywords = annotations.get(ANNOTATION_PREFIX + "keywords", "")

        # Service group categorization
        group = annotations.get(SERVICE_ANNOTATION_PREFIX + "name", "")
        group_icon = annotations.get(SERVICE_ANNOTATION_PREFIX + "icon", "")

        # Fallback: derive group from gateway name
        if not group:
            gateway_names = [
                ref.get("name", "") for ref in spec.get("parentRefs", [])
            ]
            for gw in gateway_names:
                if gw in GATEWAY_NAMES:
                    group = GATEWAY_NAMES[gw]
                    break
            if not group:
                group = "Other"

        # Fallback group icon
        if not group_icon:
            group_icon = KNOWN_GROUP_ICONS.get(group, "📌")

        # If no display name, derive from hostname
        if not display_name and hostname:
            display_name = hostname.split(".")[0].capitalize()

        # Determine icon
        if not logo:
            icon = GATEWAY_ICONS.get(
                next(
                    (
                        ref.get("name", "")
                        for ref in spec.get("parentRefs", [])
                        if ref.get("name", "") in GATEWAY_ICONS
                    ),
                    "",
                ),
                "🔗",
            )
        else:
            icon = None  # logo present, will render with <img>

        item = {
            "name": display_name or hostname or name,
            "url": f"https://{hostname}/" if hostname else "",
            "subtitle": subtitle,
            "logo": logo,
            "icon": icon,
            "keywords": keywords,
            "group": group,
            "group_icon": group_icon,
        }
        apps[f"{ns}/{name}"] = item

    # 4. Organize by service group
    grouped = {}
    for key, item in sorted(apps.items()):
        g = item["group"]
        if g not in grouped:
            grouped[g] = {
                "name": g,
                "icon": item["group_icon"],
                "items": [],
            }
        grouped[g]["items"].append(item)

    result = {
        "groups": [grouped[g] for g in sorted(grouped.keys())],
    }
    DISCOVERY_CACHE["data"] = result
    DISCOVERY_CACHE["expires_at"] = now + CACHE_TTL
    return result


# ── HTML rendering ────────────────────────────────────────────────────────────

HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>keiretsu home</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>\U0001F3E0</text></svg>">
  <style>{style}</style>
</head>
<body>
"""

FOOT = """</body></html>"""


def render_greeting(name):
    return (
        f'<section class="card greeting">'
        f'<h1>\U0001F44B hey {name}</h1>'
        f'<p class="subtitle">keiretsu cloud \u00b7 home</p>'
        f'</section>'
    )


def render_group_section(group):
    items_html = ""
    for item in group.get("items", []):
        if item["logo"]:
            logo_html = f'<img class="link-logo" src="{item["logo"]}" alt="">'
        elif item["icon"]:
            logo_html = f'<span class="link-icon">{item["icon"]}</span>'
        else:
            logo_html = '<span class="link-icon">\U0001F517</span>'

        subtitle_html = (
            f'<span class="link-subtitle">{item["subtitle"]}</span>'
            if item["subtitle"]
            else ""
        )

        items_html += (
            f'<a href="{item["url"]}" class="link-card" target="_blank">'
            f'{logo_html}'
            f'<span class="link-text">'
            f'<span class="link-label">{item["name"]}</span>'
            f'{subtitle_html}'
            f'</span>'
            f'</a>'
        )

    icon = group.get("icon", "\U0001F4CC")
    return (
        f'<section class="card">'
        f'<h2>{icon} {group["name"]}</h2>'
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

        metrics = fetch_garage_metrics()
        html = render_garage_page(template, metrics)

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

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
