"""holmes-shim: FastMCP wrapper around HolmesGPT /api/chat + Alertmanager/Gatus webhook receiver.

Exposes one MCP tool (investigate) that proxies to Holmes /api/chat, and HTTP routes
that turn Alertmanager/Gatus webhooks into Holmes investigations — posting the result
to Discord so the analysis reaches a human instead of being discarded.
"""
import json
import os
import uuid

import httpx
from fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

mcp = FastMCP("holmes-shim")

HOLMES_URLS: dict[str, str] = json.loads(
    os.environ.get(
        "HOLMES_URLS",
        '{"central": "http://holmes.ai-sre.svc.cluster.local:80"}',
    )
)
DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")
TIMEOUT = 120.0


async def post_to_discord(title: str, description: str, color: int = 0x5865F2) -> None:
    """Post a rich embed to the configured Discord webhook. Best-effort: logs on failure."""
    if not DISCORD_WEBHOOK_URL:
        return
    # Discord embed description cap is 4096; title cap is 256. Clamp to avoid 400s.
    payload = {
        "username": "HolmesGPT",
        "embeds": [
            {
                "title": title[:256],
                "description": description[:4096],
                "color": color,
            }
        ],
    }
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(DISCORD_WEBHOOK_URL, json=payload)
            if resp.status_code >= 400:
                print(f"discord post failed: HTTP {resp.status_code} {resp.text[:200]}")
    except Exception as e:
        print(f"discord post error: {type(e).__name__}: {e}")


@mcp.tool
async def investigate(question: str, cluster: str = "central") -> str:
    """Investigate an SRE question via HolmesGPT for the specified cluster.

    Args:
        question: Natural-language question or issue description to investigate.
        cluster: Target cluster key — must match a key in HOLMES_URLS
                 (e.g. "central", "robbinsdale", "stpetersburg").

    Returns:
        Holmes analysis text, or an "error: ..." string if Holmes is unreachable.
    """
    base = HOLMES_URLS.get(cluster)
    if not base:
        return f"error: no Holmes URL configured for cluster '{cluster}'"

    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.post(
                f"{base}/api/chat",
                json={
                    "conversation_id": f"mcp-{uuid.uuid4()}",
                    "user_prompt": question,
                },
            )
            resp.raise_for_status()
            try:
                data = resp.json()
                return data.get("output") or data.get("response") or json.dumps(data)
            except (json.JSONDecodeError, ValueError):
                return resp.text
    except httpx.TimeoutException:
        return f"error: Holmes timed out after {int(TIMEOUT)}s for cluster '{cluster}'"
    except httpx.ConnectError:
        return f"error: Holmes unreachable at {base} (cluster '{cluster}')"
    except httpx.HTTPStatusError as e:
        return f"error: Holmes returned HTTP {e.response.status_code} for cluster '{cluster}'"
    except Exception as e:
        return f"error: {type(e).__name__}: {e}"


@mcp.custom_route("/alertmanager", methods=["POST"])
async def alertmanager_webhook(request: Request) -> JSONResponse:
    """Receive Alertmanager webhooks: investigate each alert, post the result to Discord."""
    try:
        payload = await request.json()
    except Exception:
        return JSONResponse({"status": "ok"}, status_code=200)

    alerts = payload.get("alerts", []) if isinstance(payload, dict) else []
    if not alerts and isinstance(payload, dict):
        alerts = [payload]

    for alert in alerts:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alertname = labels.get("alertname", "unknown")
        status = alert.get("status", "firing")
        summary = annotations.get("summary", "")
        description = annotations.get("description", "")

        parts = [f"[{status.upper()}] Alert: {alertname}"]
        if summary:
            parts.append(f"Summary: {summary}")
        if description:
            parts.append(f"Description: {description}")
        extra_labels = {k: v for k, v in labels.items() if k != "alertname"}
        if extra_labels:
            parts.append(f"Labels: {json.dumps(extra_labels)}")

        question = "\n".join(parts)
        cluster = labels.get("cluster", "central")

        result = await investigate(question=question, cluster=cluster)

        title = f"[{status.upper()}] {alertname}" if status != "firing" else alertname
        color = 0xE74C3C if status == "firing" else 0x2ECC71
        await post_to_discord(title=title, description=result, color=color)

    return JSONResponse({"status": "ok"}, status_code=200)


@mcp.custom_route("/gatus", methods=["POST"])
async def gatus_webhook(request: Request) -> JSONResponse:
    """Receive Gatus webhook alerts: investigate the failing endpoint, post result to Discord.

    Gatus sends: {"event":"ALERT"|"RESOLVED","endpoint_group":"...","endpoint_name":"...",
                 "message":"...","results":[{"status":...,"errors":...}]}
    """
    try:
        payload = await request.json()
    except Exception:
        return JSONResponse({"status": "ok"}, status_code=200)

    if not isinstance(payload, dict):
        return JSONResponse({"status": "ok"}, status_code=200)

    event = payload.get("event", "ALERT")
    group = payload.get("endpoint_group", "unknown")
    name = payload.get("endpoint_name", "unknown")
    message = payload.get("message", "")
    cluster = payload.get("cluster", "central")

    if event == "RESOLVED":
        await post_to_discord(
            title=f"[RESOLVED] {group}/{name}",
            description=f"Gatus check recovered: {message}",
            color=0x2ECC71,
        )
        return JSONResponse({"status": "ok"}, status_code=200)

    question = (
        f"[ALERT] Gatus health check failing\n"
        f"Endpoint: {group}/{name}\n"
        f"Message: {message}\n"
        f"Investigate why this endpoint is failing. Check the relevant pods, "
        f"services, and recent changes."
    )

    result = await investigate(question=question, cluster=cluster)
    await post_to_discord(
        title=f"[ALERT] {group}/{name}",
        description=result,
        color=0xE74C3C,
    )

    return JSONResponse({"status": "ok"}, status_code=200)


if __name__ == "__main__":
    import uvicorn
    app = mcp.http_app(transport="streamable-http", allowed_hosts=["*"], host_origin_protection=False)
    uvicorn.run(app, host="0.0.0.0", port=8000)
