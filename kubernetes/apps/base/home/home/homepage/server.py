#!/usr/bin/env python3
"""Personalized home.keiretsu.top — reads Remote-Email from tinyauth, renders user-specific page."""

import json
import os
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

USERS_PATH = Path("/etc/homepage/users.json")
STYLE_PATH = Path("/etc/homepage/style.css")

# ── user config loader ────────────────────────────────────────────────────────

def load_users():
    """Load user profiles from JSON. Returns dict[email -> user]."""
    data = json.loads(USERS_PATH.read_text())
    return {u["email"]: u for u in data.get("users", [])}

def load_style():
    if STYLE_PATH.exists():
        return STYLE_PATH.read_text()
    return ""

# ── HTML rendering ────────────────────────────────────────────────────────────

HEAD = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>keiretsu home</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🏠</text></svg>">
  <style>{style}</style>
</head>
<body>
"""

FOOT = """</body></html>"""

def render_greeting(user):
    name = user.get("display_name", user.get("email", "friend"))
    return f'<section class="card greeting"><h1>👋 hey {name}</h1><p class="subtitle">keiretsu cloud · home</p></section>'

def render_quick_links(user):
    links = user.get("quick_links", [])
    if not links:
        return ""
    items = "".join(
        f'<a href="{l["url"]}" class="link-card" target="_blank">'
        f'<span class="link-icon">{l.get("icon", "🔗")}</span>'
        f'<span class="link-label">{l["name"]}</span></a>'
        for l in links
    )
    return f'<section class="card"><h2>📌 quick links</h2><div class="link-grid">{items}</div></section>'

def render_agents(user):
    agents = user.get("agents", [])
    if not agents:
        return ""
    items = "".join(
        f'<a href="{a["url"]}" class="link-card agent" target="_blank">'
        f'<span class="link-icon">{a.get("icon", "🤖")}</span>'
        f'<span class="link-label">{a["name"]}</span></a>'
        for a in agents
    )
    return f'<section class="card"><h2>🤖 agents</h2><div class="link-grid">{items}</div></section>'

def render_section(user, key, title, icon, render_fn):
    items = render_fn(user, key)
    if not items:
        return ""
    return f'<section class="card"><h2>{icon} {title}</h2><div class="link-grid">{items}</div></section>'

def render_links(user, key):
    links = user.get(key, [])
    return "".join(
        f'<a href="{l["url"]}" class="link-card" target="_blank">'
        f'<span class="link-icon">{l.get("icon", "🔗")}</span>'
        f'<span class="link-label">{l["name"]}</span></a>'
        for l in links
    )

def render_unknown(email):
    """Fallback for authenticated but unconfigured users."""
    return f"""<section class="card greeting">
<h1>👋 welcome</h1>
<p class="subtitle">you're logged in as {email}</p>
<p class="note">your profile hasn't been set up yet — talk to your admin to add bookmarks.</p>
</section>"""

def render_page(user, style):
    if user:
        body = render_greeting(user)
        body += render_section(user, "quick_links", "quick links", "📌", render_links)
        body += render_section(user, "agents", "agents", "🤖", render_links)
        body += render_section(user, "infra", "infrastructure", "⚙️", render_links)
        body += render_section(user, "media", "media", "🎬", render_links)
    else:
        body = render_unknown("unknown")
    return HEAD.format(style=style) + body + FOOT

# ── HTTP handler ──────────────────────────────────────────────────────────────

class HomepageHandler(BaseHTTPRequestHandler):
    users = {}
    style = ""

    def do_GET(self):
        if self.path != "/":
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return

        email = self.headers.get("Remote-Email", "").strip().lower()
        user = self.users.get(email)

        html = render_page(user, self.style)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(html.encode("utf-8"))

    def log_message(self, format, *args):
        # Quiet logging — no per-request noise in pod logs
        pass


def main():
    # hot-reload config on every request for now (ConfigMap updates = new content)
    style = load_style()
    users = load_users()
    HomepageHandler.users = users
    HomepageHandler.style = style

    port = int(os.environ.get("PORT", "8080"))
    server = HTTPServer(("0.0.0.0", port), HomepageHandler)
    print(f"homepage server listening on :{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()