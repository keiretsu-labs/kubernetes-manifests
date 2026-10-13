"""Refresh the ops bot kubeconfig from a short-lived TokenRequest."""

import base64
import datetime
import json
import ssl
import urllib.error
import urllib.request
from pathlib import Path


API = "https://kubernetes.default.svc"
NAMESPACE = "bhaiya"
BOT = "bhaiya-ops-bot"
TARGET = "bhaiya-ops-bot-kubeconfig"
MIN_VALIDITY = datetime.timedelta(minutes=20)


def request_json(url, method, bearer, ca_file, body, content_type):
    request = urllib.request.Request(
        url,
        data=json.dumps(body, separators=(",", ":")).encode(),
        method=method,
        headers={"Authorization": f"Bearer {bearer}", "Content-Type": content_type},
    )
    try:
        with urllib.request.urlopen(
            request, context=ssl.create_default_context(cafile=ca_file), timeout=20
        ) as response:
            if response.status not in (200, 201):
                raise RuntimeError(f"Kubernetes API returned HTTP {response.status}")
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Kubernetes API returned HTTP {error.code}") from None
    except urllib.error.URLError:
        raise RuntimeError("Kubernetes API request failed") from None


def token_from_response(response, now):
    status = response.get("status", {})
    token = status.get("token")
    timestamp = status.get("expirationTimestamp")
    if not isinstance(token, str) or not token or not isinstance(timestamp, str):
        raise RuntimeError("TokenRequest returned no token or expiration")
    try:
        expires = datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        raise RuntimeError("TokenRequest returned an invalid expiration") from None
    if expires.tzinfo is None or expires - now < MIN_VALIDITY:
        raise RuntimeError("TokenRequest token expires in less than 20 minutes")
    return token


def kubeconfig(token, ca_data):
    return {
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [{
            "name": "ottawa",
            "cluster": {
                "server": API,
                "certificate-authority-data": base64.b64encode(ca_data).decode("ascii"),
            },
        }],
        "contexts": [{
            "name": BOT,
            "context": {"cluster": "ottawa", "user": BOT},
        }],
        "current-context": BOT,
        "users": [{"name": BOT, "user": {"token": token}}],
    }


def main():
    credential_dir = Path("/var/run/ops-bot-sync")
    job_token = (credential_dir / "token").read_text().strip()
    ca_file = credential_dir / "ca.crt"
    ca_data = ca_file.read_bytes()
    if not job_token or not ca_data:
        raise RuntimeError("sync Job credentials are missing")

    response = request_json(
        f"{API}/api/v1/namespaces/{NAMESPACE}/serviceaccounts/{BOT}/token",
        "POST", job_token, str(ca_file),
        {"apiVersion": "authentication.k8s.io/v1", "kind": "TokenRequest", "spec": {"expirationSeconds": 3600}},
        "application/json",
    )
    token = token_from_response(response, datetime.datetime.now(datetime.timezone.utc))
    config = json.dumps(kubeconfig(token, ca_data), separators=(",", ":")).encode()
    request_json(
        f"{API}/api/v1/namespaces/{NAMESPACE}/secrets/{TARGET}",
        "PATCH", job_token, str(ca_file),
        {"data": {"config": base64.b64encode(config).decode("ascii")}},
        "application/merge-patch+json",
    )
    print("ops bot kubeconfig Secret synchronized")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error)) from None
