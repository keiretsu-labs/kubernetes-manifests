"""holmes-shim: FastMCP wrapper around HolmesGPT /api/chat + Alertmanager webhook receiver.

Exposes one MCP tool (investigate) that proxies to Holmes /api/chat, and one HTTP
route (POST /alertmanager) that turns Alertmanager webhooks into Holmes investigations.
The MCP endpoint is served at /mcp (Streamable-HTTP) for Bifrost to proxy to.
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
TIMEOUT = 120.0


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
    """Receive Alertmanager webhooks and forward each alert as a Holmes investigation."""
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
        try:
            await investigate(question=question, cluster=cluster)
        except Exception:
            pass

    return JSONResponse({"status": "ok"}, status_code=200)


if __name__ == "__main__":
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)
