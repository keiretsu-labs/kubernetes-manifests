#!/usr/bin/env bash
# tools/check-diagram.sh — gate for the embedded Graphviz architecture diagram
# in README.md. Three independent checks, in order:
#
#   SYNTAX       the fenced ```dot block parses as a real Graphviz graph
#                (uses `dot` if installed, else a @hpcc-js/wasm-graphviz copy
#                under node_modules, else a structural brace/quote fallback)
#   SECRETS      no key material, token, credential, e-mail address, public IP
#                or tailnet CGNAT address appears in the diagram
#   COVERAGE     every cluster, Talos node, namespace and Flux Kustomization
#                that exists on disk is named somewhere in the diagram, and
#                every app the diagram names still exists on disk
#
# COVERAGE is the anti-drift half: adding an app without drawing it fails, and
# deleting an app without erasing it from the diagram fails too.
#
# Exit 0 = clean, 1 = findings, 2 = bad usage / diagram block not found.
#
# Usage:
#   tools/check-diagram.sh              # check README.md
#   tools/check-diagram.sh <file.md>    # check another markdown file
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${1:-$ROOT/README.md}"
[ -f "$DOC" ] || { echo "check-diagram.sh: not a file: $DOC" >&2; exit 2; }

DOT="$(mktemp)"; trap 'rm -f "$DOT"' EXIT

# ---------------------------------------------------------------- extract
# Pull every ```dot fenced block out of the markdown and concatenate them.
awk '
  /^[[:space:]]*```dot[[:space:]]*$/ { inb=1; n++; next }
  /^[[:space:]]*```[[:space:]]*$/    { if (inb) { inb=0 }; next }
  inb { print }
  END { if (n==0) exit 3 }
' "$DOC" >"$DOT"
case $? in
  0) : ;;
  3) echo "check-diagram.sh: no \`\`\`dot block found in ${DOC#"$ROOT"/}" >&2; exit 2 ;;
  *) echo "check-diagram.sh: failed to read ${DOC#"$ROOT"/}" >&2; exit 2 ;;
esac
[ -s "$DOT" ] || { echo "check-diagram.sh: \`\`\`dot block is empty" >&2; exit 2; }

rc=0
note() { printf '%s\n' "$*"; rc=1; }

# ---------------------------------------------------------------- syntax
engine=""
if command -v dot >/dev/null 2>&1; then
  engine="dot"
  if ! err="$(dot -Tsvg -o /dev/null "$DOT" 2>&1)"; then
    note "SYNTAX    graphviz rejected the diagram:"
    printf '%s\n' "$err" | sed 's/^/          /'
  fi
else
  # Look for a wasm graphviz next to the repo or in the ambient node path.
  wasm=""
  for d in "$ROOT/node_modules" "$ROOT/tools/node_modules" "${NODE_PATH:-}" /tmp/node_modules; do
    [ -n "$d" ] && [ -f "$d/@hpcc-js/wasm-graphviz/dist/index.js" ] &&
      { wasm="$d/@hpcc-js/wasm-graphviz/dist/index.js"; break; }
  done
  if [ -n "$wasm" ] && command -v node >/dev/null 2>&1; then
    engine="wasm-graphviz"
    if ! err="$(node --input-type=module -e '
        import { readFileSync } from "node:fs";
        const { Graphviz } = await import(process.argv[2]);
        const gv = await Graphviz.load();
        gv.layout(readFileSync(process.argv[1], "utf8"), "svg", "dot");
      ' "$DOT" "$wasm" 2>&1)"; then
      note "SYNTAX    graphviz (wasm) rejected the diagram:"
      printf '%s\n' "$err" | sed 's/^/          /'
    fi
  else
    engine="fallback"
    # No graphviz available: check the structural invariants we can check
    # cheaply — balanced braces/brackets outside strings, balanced quotes,
    # a graph header, and no stray edge operator at end of statement.
    python3 - "$DOT" <<'PY' || rc=1
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# strip comments and string literals, tracking quote balance
i, n, out, depth, brack, quotes = 0, len(src), [], 0, 0, 0
while i < n:
    c = src[i]
    if c == '"':
        quotes += 1
        i += 1
        while i < n:
            if src[i] == '\\': i += 2; continue
            if src[i] == '"': quotes += 1; i += 1; break
            i += 1
        out.append(' ')
        continue
    if src.startswith("//", i) or src.startswith("#", i):
        j = src.find("\n", i); i = n if j < 0 else j; continue
    if src.startswith("/*", i):
        j = src.find("*/", i + 2); i = n if j < 0 else j + 2; continue
    if c == '{': depth += 1
    elif c == '}': depth -= 1
    elif c == '[': brack += 1
    elif c == ']': brack -= 1
    if depth < 0 or brack < 0:
        print(f"SYNTAX    unbalanced {'brace' if depth<0 else 'bracket'} near offset {i}")
        sys.exit(1)
    out.append(c); i += 1
if depth or brack:
    print(f"SYNTAX    unclosed braces={depth} brackets={brack}")
    sys.exit(1)
if quotes % 2:
    print("SYNTAX    odd number of double quotes")
    sys.exit(1)
body = "".join(out)
if not re.search(r'\b(strict\s+)?(di)?graph\b', body):
    print("SYNTAX    no graph/digraph header found")
    sys.exit(1)
if re.search(r'(->|--)\s*[;}]', body):
    print("SYNTAX    dangling edge operator before ; or }")
    sys.exit(1)
PY
  fi
fi

# ---------------------------------------------------------------- secrets
python3 - "$DOT" <<'PY' || rc=1
import ipaddress, re, sys

src = open(sys.argv[1], encoding="utf-8").read()
lines = src.splitlines()
findings = []

# Lines the author explicitly vouched for.
def allowed(ln: str) -> bool:
    return "diagram-check: allow" in ln

PATTERNS = [
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "private key block"),
    (r"-----BEGIN CERTIFICATE-----",        "certificate block"),
    (r"\btskey-[A-Za-z0-9-]{6,}",           "tailscale auth key"),
    (r"\bAKIA[0-9A-Z]{12,}",                "AWS access key id"),
    (r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}", "GitHub token"),
    (r"\bgithub_pat_[A-Za-z0-9_]{20,}",     "GitHub fine-grained PAT"),
    (r"\bxox[baprs]-[A-Za-z0-9-]{10,}",     "Slack token"),
    (r"\bsk-[A-Za-z0-9]{20,}",              "OpenAI-style API key"),
    (r"\bAIza[0-9A-Za-z_-]{30,}",           "Google API key"),
    (r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}", "JWT"),
    (r"\$2[aby]\$\d{2}\$[./A-Za-z0-9]{20,}", "bcrypt hash"),
    (r"\bENC\[",                            "SOPS ciphertext"),
    (r"\bsops:\s*$",                        "SOPS metadata block"),
    (r"(?i)\b(client[_-]?secret|auth[_-]?key|api[_-]?key|password|passwd|secret[_-]?key|access[_-]?key)\s*[:=]\s*\S", "inline credential assignment"),
    (r"[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]{2,}", "e-mail address"),
    (r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b", "MAC address"),
    # Disk/board serials live in talconfig for device selection. They identify
    # physical hardware and have no place in a published diagram.
    (r"(?i)\bserial\s*[:=]\s*\S", "hardware serial number"),
    (r"\b(?=[0-9A-Z]{12,20}\b)(?=[0-9A-Z]*[0-9])(?=[0-9A-Z]*[A-Z])[0-9A-Z]{12,20}\b",
     "possible hardware serial"),
]

for idx, ln in enumerate(lines, 1):
    if allowed(ln):
        continue
    for pat, what in PATTERNS:
        m = re.search(pat, ln)
        if m:
            findings.append(f"SECRETS   line {idx}: {what}")
            break

# Long opaque base64-ish runs, excluding content-addressed digests.
for idx, ln in enumerate(lines, 1):
    if allowed(ln):
        continue
    scrub = re.sub(r"sha(?:256|512)[:-][0-9a-fA-F]+", " ", ln)
    for tok in re.findall(r"[A-Za-z0-9+/]{48,}={0,2}", scrub):
        if re.fullmatch(r"[0-9a-fA-F]+", tok):   # plain hex digest
            continue
        findings.append(f"SECRETS   line {idx}: {len(tok)}-char opaque blob")
        break

# IP literals: private/link-local/loopback are documented on purpose; public
# addresses would leak the WAN edge and CGNAT would leak tailnet addressing.
OK_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
    "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
)]
CGNAT = ipaddress.ip_network("100.64.0.0/10")
for idx, ln in enumerate(lines, 1):
    if allowed(ln):
        continue
    for cand in re.findall(r"(?<![\w.:-])(\d{1,3}(?:\.\d{1,3}){3})(?![\w.]*[A-Za-z])", ln):
        try:
            ip = ipaddress.ip_address(cand)
        except ValueError:
            continue
        if ip in CGNAT:
            findings.append(f"SECRETS   line {idx}: tailnet CGNAT address {cand}")
        elif not any(ip in net for net in OK_NETS) and not ip.is_unspecified:
            findings.append(f"SECRETS   line {idx}: public IP address {cand}")

for f in sorted(set(findings)):
    print(f)
sys.exit(1 if findings else 0)
PY

# ---------------------------------------------------------------- coverage
python3 - "$ROOT" "$DOT" <<'PY' || rc=1
import os, re, sys

root, dotfile = sys.argv[1], sys.argv[2]
dot = open(dotfile, encoding="utf-8").read()

APPS = os.path.join(root, "kubernetes", "apps")
LOCATIONS = sorted(
    d for d in os.listdir(APPS)
    if d != "base" and os.path.isdir(os.path.join(APPS, d))
) if os.path.isdir(APPS) else []

missing, stale = [], []

def require(kind, name, where):
    if name and name not in dot:
        missing.append(f"COVERAGE  {kind} not in diagram: {name}  ({where})")

# --- clusters, domains, CIDRs, Talos nodes -----------------------------------
for loc in LOCATIONS:
    require("location", loc, "kubernetes/apps/")
    settings = os.path.join(root, "clusters", f"talos-{loc}", "flux", "vars",
                            "cluster-settings.yaml")
    if os.path.isfile(settings):
        txt = open(settings, encoding="utf-8").read()
        for key in ("CLUSTER_NAME", "CLUSTER_DOMAIN", "CLUSTER_POD_CIDR",
                    "CLUSTER_SERVICE_CIDR", "CLUSTER_LOAD_BALANCER_CIDR",
                    "LAN_CIDR", "KUBERNETES_API_VIP"):
            m = re.search(rf"^\s*{key}:\s*\"?([^\"\s#]+)", txt, re.M)
            if m:
                require(f"{loc} {key}", m.group(1), settings.replace(root + "/", ""))

    tal = os.path.join(root, "clusters", f"talos-{loc}", "bootstrap", "talos",
                       "talconfig.yaml")
    if os.path.isfile(tal):
        txt = open(tal, encoding="utf-8").read()
        for host in re.findall(r"^\s*-?\s*hostname:\s*\"?([A-Za-z0-9][\w.-]*)", txt, re.M):
            require(f"{loc} node", host, tal.replace(root + "/", ""))

# --- namespaces and Flux Kustomization pointers ------------------------------
# Pointer files hold several kinds (Kustomization, GitRepository, Receiver,
# Secret...). Only the Flux Kustomization names are the app identities, so parse
# properly rather than grepping `name:` — nested sourceRef/substitute names
# would otherwise masquerade as apps.
try:
    import yaml
except ImportError:
    yaml = None

KUSTOMIZATION = re.compile(r"kustomize\.toolkit\.fluxcd\.io/v1")
META_NAME = re.compile(
    r"^metadata:\s*$(?:\n(?:[ \t]+.*)?$)*?\n[ \t]+name:[ \t]*(?:&\S+[ \t]+)?[\"']?"
    r"([A-Za-z0-9][\w.-]*)", re.M)

def kustomization_names(text):
    """Flux Kustomization metadata.name values in a multi-doc YAML string."""
    names = []
    docs = re.split(r"^---\s*$", text, flags=re.M)
    for doc in docs:
        if not KUSTOMIZATION.search(doc):
            continue
        if not re.search(r"^\s*kind:\s*Kustomization\s*$", doc, re.M):
            continue
        obj = None
        if yaml is not None:
            try:
                obj = yaml.safe_load(doc)
            except Exception:
                obj = None
        if isinstance(obj, dict):
            n = (obj.get("metadata") or {}).get("name")
            if isinstance(n, str) and n:
                names.append(n)
                continue
        m = META_NAME.search(doc)
        if m:
            names.append(m.group(1))
    return names

drawn_apps = set()
for loc in LOCATIONS:
    locdir = os.path.join(APPS, loc)
    for ns in sorted(os.listdir(locdir)):
        nsdir = os.path.join(locdir, ns)
        if not os.path.isdir(nsdir):
            continue
        require(f"{loc} namespace", ns, f"kubernetes/apps/{loc}/")
        for dirpath, _, files in os.walk(nsdir):
            for fn in sorted(files):
                if not fn.endswith((".yaml", ".yml")):
                    continue
                if fn in ("kustomization.yaml", "namespace.yaml"):
                    continue
                path = os.path.join(dirpath, fn)
                try:
                    txt = open(path, encoding="utf-8").read()
                except OSError:
                    continue
                rel = path.replace(root + "/", "")
                for name in kustomization_names(txt):
                    drawn_apps.add(name)
                    require(f"{loc} app", name, rel)

# --- reverse direction: diagram must not name apps that no longer exist ------
# Only audit identifiers the diagram marks as apps with a trailing "(app)"
# free-form tag or an app_ node-id prefix, so prose labels stay unconstrained.
for ident in set(re.findall(r'\bapp_([A-Za-z0-9][\w.-]*)\b', dot)):
    name = ident.replace("_", "-")
    if name not in drawn_apps and ident not in drawn_apps:
        stale.append(f"COVERAGE  diagram names app that is not deployed: {name}")

for line in sorted(set(missing)) + sorted(set(stale)):
    print(line)
sys.exit(1 if (missing or stale) else 0)
PY

if [ "$rc" = 0 ]; then
  printf '✓ diagram OK: %s (syntax=%s)\n' "${DOC#"$ROOT"/}" "$engine"
fi
exit "$rc"
