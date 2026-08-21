#!/usr/bin/env bash
# tools/check-diagram.sh — gate for the architecture diagrams under
# docs/diagrams/ and the reference docs they lean on. Six independent checks:
#
#   SYNTAX     every docs/diagrams/*.dot parses as a real Graphviz graph
#              (uses `dot` if installed, else a @hpcc-js/wasm-graphviz copy
#              under node_modules, else a structural brace/quote fallback)
#   SECRETS    no key material, token, credential, e-mail address, hardware
#              serial, public IP or tailnet CGNAT address appears in a diagram
#              or in the reference docs
#   STALE      each committed .svg was rendered from the .dot beside it
#   INVENTORY  docs/reference/inventory.md matches the tree
#   COVERAGE   every location, cluster setting, Talos machine, namespace and
#              Flux Kustomization on disk is named somewhere in the docs
#   LINKS      every diagram is referenced by the README, and every diagram the
#              README references exists
#
# COVERAGE is the anti-drift half. Most of it is satisfied by
# docs/reference/inventory.md, which tools/gen-inventory.sh generates from the
# tree — so adding an app cannot leave the docs behind, it can only leave them
# UNREGENERATED, which INVENTORY catches. What a human still owns is the
# diagrams and the narrative, and a diagram that names an app it should not is
# caught by the `// diagram-apps:` declaration described below.
#
# Declaring apps a diagram names:
#   // diagram-apps: bhaiya, hermes, forgejo
# Every name listed must still be a Flux Kustomization on disk. This is how
# deleting an app fails the build instead of quietly leaving a lie in a picture.
#
# Exit 0 = clean, 1 = findings, 2 = bad usage / no diagram source found.
#
# Usage:
#   tools/check-diagram.sh                # every docs/diagrams/*.dot
#   tools/check-diagram.sh <file.dot>     # one diagram
#   tools/check-diagram.sh <file.md>      # ```dot blocks inside a markdown file
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DIAGRAMS="$ROOT/docs/diagrams"

TMPDIR_="$(mktemp -d)"; trap 'rm -rf "$TMPDIR_"' EXIT

# ---------------------------------------------------------------- collect
# Each entry is "<label>|<path to a dot file on disk>|<svg to compare or ->".
SOURCES=()

add_dot_file() {
  # The light and dark renderings are both derived from this one source and
  # both carry its stamp, so both are checked for staleness.
  local f="$1" svgs=""
  for cand in "${1%.dot}.svg" "${1%.dot}.dark.svg"; do
    [ -f "$cand" ] && svgs="${svgs:+$svgs,}$cand"
  done
  SOURCES+=("${f#"$ROOT"/}|$f|${svgs:--}")
}

add_markdown() {
  # Pull every ```dot fenced block out of a markdown file and treat the
  # concatenation as one graph, the way the diagram used to be embedded.
  local doc="$1" out="$TMPDIR_/md-$(echo "$doc" | md5sum | cut -c1-8).dot"
  awk '
    /^[[:space:]]*```dot[[:space:]]*$/ { inb=1; n++; next }
    /^[[:space:]]*```[[:space:]]*$/    { if (inb) { inb=0 }; next }
    inb { print }
    END { if (n==0) exit 3 }
  ' "$doc" >"$out"
  case $? in
    0) : ;;
    3) echo "check-diagram.sh: no \`\`\`dot block found in ${doc#"$ROOT"/}" >&2; exit 2 ;;
    *) echo "check-diagram.sh: failed to read ${doc#"$ROOT"/}" >&2; exit 2 ;;
  esac
  [ -s "$out" ] || { echo "check-diagram.sh: \`\`\`dot block is empty" >&2; exit 2; }
  SOURCES+=("${doc#"$ROOT"/}|$out|-")
}

if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    [ -f "$arg" ] || { echo "check-diagram.sh: not a file: $arg" >&2; exit 2; }
    case "$arg" in
      *.dot) add_dot_file "$arg" ;;
      *)     add_markdown "$arg" ;;
    esac
  done
else
  while IFS= read -r f; do add_dot_file "$f"; done \
    < <(find "$DIAGRAMS" -maxdepth 1 -name '*.dot' 2>/dev/null | sort)
  [ "${#SOURCES[@]}" -gt 0 ] || {
    echo "check-diagram.sh: no .dot files under docs/diagrams/" >&2; exit 2; }
fi

rc=0
note() { printf '%s\n' "$*"; rc=1; }

# ---------------------------------------------------------------- syntax
engine=""
wasm=""
if command -v dot >/dev/null 2>&1; then
  engine="dot"
else
  for d in "$ROOT/node_modules" "$ROOT/tools/node_modules" "${NODE_PATH:-}" /tmp/node_modules; do
    [ -n "$d" ] && [ -f "$d/@hpcc-js/wasm-graphviz/dist/index.js" ] &&
      { wasm="$d/@hpcc-js/wasm-graphviz/dist/index.js"; break; }
  done
  if [ -n "$wasm" ] && command -v node >/dev/null 2>&1; then
    engine="wasm-graphviz"
  else
    engine="fallback"
  fi
fi

for entry in "${SOURCES[@]}"; do
  label="${entry%%|*}"; rest="${entry#*|}"; dot="${rest%%|*}"
  case "$engine" in
    dot)
      if ! err="$(dot -Tsvg -o /dev/null "$dot" 2>&1)"; then
        note "SYNTAX    graphviz rejected $label:"
        printf '%s\n' "$err" | sed 's/^/          /'
      fi
      ;;
    wasm-graphviz)
      if ! err="$(node --input-type=module -e '
          import { readFileSync } from "node:fs";
          const { Graphviz } = await import(process.argv[2]);
          const gv = await Graphviz.load();
          gv.layout(readFileSync(process.argv[1], "utf8"), "svg", "dot");
        ' "$dot" "$wasm" 2>&1)"; then
        note "SYNTAX    graphviz (wasm) rejected $label:"
        printf '%s\n' "$err" | sed 's/^/          /'
      fi
      ;;
    fallback)
      # No graphviz available: check the structural invariants we can check
      # cheaply — balanced braces/brackets outside strings, balanced quotes,
      # a graph header, and no stray edge operator at end of statement.
      python3 - "$dot" "$label" <<'PY' || rc=1
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
label = sys.argv[2]
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
        print(f"SYNTAX    {label}: unbalanced {'brace' if depth<0 else 'bracket'} near offset {i}")
        sys.exit(1)
    out.append(c); i += 1
if depth or brack:
    print(f"SYNTAX    {label}: unclosed braces={depth} brackets={brack}")
    sys.exit(1)
if quotes % 2:
    print(f"SYNTAX    {label}: odd number of double quotes")
    sys.exit(1)
body = "".join(out)
if not re.search(r'\b(strict\s+)?(di)?graph\b', body):
    print(f"SYNTAX    {label}: no graph/digraph header found")
    sys.exit(1)
if re.search(r'(->|--)\s*[;}]', body):
    print(f"SYNTAX    {label}: dangling edge operator before ; or }}")
    sys.exit(1)
PY
      ;;
  esac
done

# ---------------------------------------------------------------- staleness
# Engine-independent: no renderer needed, just the stamp that
# tools/render-diagram.sh writes.
for entry in "${SOURCES[@]}"; do
  label="${entry%%|*}"; rest="${entry#*|}"; dot="${rest%%|*}"; svglist="${rest#*|}"
  [ "$svglist" = "-" ] && continue
  want="$(sha256sum "$dot" | cut -d' ' -f1)"
  while IFS= read -r svg; do
    [ -n "$svg" ] || continue
    got="$(sed -n 's/.*diagram-source-sha256: \([0-9a-f]\{64\}\).*/\1/p' "$svg" | tail -1)"
    rel="${svg#"$ROOT"/}"
    if [ -z "$got" ]; then
      note "STALE     $rel carries no source stamp — run tools/render-diagram.sh"
    elif [ "$got" != "$want" ]; then
      note "STALE     $rel was rendered from different source"
      note "          $label is ${want:0:12}, the SVG claims ${got:0:12}"
      note "          run tools/render-diagram.sh"
    fi
  done < <(printf '%s\n' "$svglist" | tr ',' '\n')
done

# ---------------------------------------------------------------- secrets
# Diagrams plus the prose that carries the same facts — a credential is no less
# leaked for being in a sentence instead of a node label.
SCAN=()
for entry in "${SOURCES[@]}"; do
  rest="${entry#*|}"; SCAN+=("${rest%%|*}")
done
for extra in "$ROOT/docs/reference/architecture.md" "$ROOT/docs/reference/inventory.md"; do
  [ -f "$extra" ] && SCAN+=("$extra")
done

python3 - "$ROOT" "${SCAN[@]}" <<'PY' || rc=1
import ipaddress, re, sys

root = sys.argv[1]
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
    # physical hardware and have no place in published documentation.
    (r"(?i)\bserial\s*[:=]\s*\S", "hardware serial number"),
    (r"\b(?=[0-9A-Z]{12,20}\b)(?=[0-9A-Z]*[0-9])(?=[0-9A-Z]*[A-Z])[0-9A-Z]{12,20}\b",
     "possible hardware serial"),
]

def looks_like_path(tok: str) -> bool:
    """True for a repo path that only happens to be long.

    base64 and a deep path share the same alphabet, so a path like
    kubernetes/apps/base/garage/garage/garagecluster trips the blob detector at
    exactly 48 characters. Real encoded material does not decompose into
    slash-separated lowercase words, so require that of every segment before
    waving it through — a mixed-case or high-entropy segment still gets flagged.
    """
    if "/" not in tok:
        return False
    segments = tok.split("/")
    if len(segments) < 3:
        return False
    return all(re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,39}", seg)
               for seg in segments if seg)


OK_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
    "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
)]
CGNAT = ipaddress.ip_network("100.64.0.0/10")

for path in sys.argv[2:]:
    rel = path.replace(root + "/", "")
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        continue
    for idx, ln in enumerate(lines, 1):
        if allowed(ln):
            continue
        for pat, what in PATTERNS:
            if re.search(pat, ln):
                findings.append(f"SECRETS   {rel}:{idx}: {what}")
                break
        # Long opaque base64-ish runs, excluding content-addressed digests.
        scrub = re.sub(r"sha(?:256|512)[:-][0-9a-fA-F]+", " ", ln)
        for tok in re.findall(r"[A-Za-z0-9+/]{48,}={0,2}", scrub):
            if re.fullmatch(r"[0-9a-fA-F]+", tok):   # plain hex digest
                continue
            if looks_like_path(tok):
                continue
            findings.append(f"SECRETS   {rel}:{idx}: {len(tok)}-char opaque blob")
            break
        # IP literals: private/link-local/loopback are documented on purpose;
        # public addresses would leak the WAN edge and CGNAT the tailnet.
        for cand in re.findall(r"(?<![\w.:-])(\d{1,3}(?:\.\d{1,3}){3})(?![\w.]*[A-Za-z])", ln):
            try:
                ip = ipaddress.ip_address(cand)
            except ValueError:
                continue
            if ip in CGNAT:
                findings.append(f"SECRETS   {rel}:{idx}: tailnet CGNAT address {cand}")
            elif not any(ip in net for net in OK_NETS) and not ip.is_unspecified:
                findings.append(f"SECRETS   {rel}:{idx}: public IP address {cand}")

for f in sorted(set(findings)):
    print(f)
sys.exit(1 if findings else 0)
PY

# ---------------------------------------------------------------- inventory
if [ -x "$ROOT/tools/gen-inventory.sh" ]; then
  if ! inv="$("$ROOT/tools/gen-inventory.sh" --check 2>&1)"; then
    printf '%s\n' "$inv" | sed 's/^/          /' | sed '1s/^ *//'
    note "INVENTORY docs/reference/inventory.md is out of date — run tools/gen-inventory.sh"
  fi
fi

# ---------------------------------------------------------------- coverage
DOT_LIST="$TMPDIR_/dots"
: >"$DOT_LIST"
for entry in "${SOURCES[@]}"; do
  rest="${entry#*|}"; printf '%s\n' "${rest%%|*}" >>"$DOT_LIST"
done

python3 - "$ROOT" "$DOT_LIST" <<'PY' || rc=1
import os, re, sys

root, dotlist = sys.argv[1], sys.argv[2]

dot_paths = [p for p in open(dotlist, encoding="utf-8").read().split("\n") if p]
dot_text = "\n".join(open(p, encoding="utf-8").read() for p in dot_paths)

# Two corpora, deliberately.
#
# HAND is what a person maintains: the diagrams, the narrative reference, the
# README. GENERATED adds docs/reference/inventory.md, which tools/gen-inventory.sh
# derives from this same tree.
#
# The distinction matters because a requirement checked against GENERATED is
# self-satisfying — the inventory lists every namespace and app by
# construction, so demanding they "appear in the docs" proves nothing about
# the hand-written half. So the few, stable, load-bearing facts (locations,
# cluster settings, Talos machines) are required in HAND, where a human has to
# actually write them down, and the long tail of namespaces and app names is
# required in GENERATED, where freshness is enforced by the INVENTORY check
# instead. Neither check is doing the other's job.
hand_parts = [dot_text]
for extra in ("docs/reference/architecture.md", "README.md"):
    p = os.path.join(root, extra)
    if os.path.isfile(p):
        hand_parts.append(open(p, encoding="utf-8").read())
hand = "\n".join(hand_parts)

generated_parts = list(hand_parts)
inv = os.path.join(root, "docs/reference/inventory.md")
if os.path.isfile(inv):
    generated_parts.append(open(inv, encoding="utf-8").read())
docs = "\n".join(generated_parts)

APPS = os.path.join(root, "kubernetes", "apps")
LOCATIONS = sorted(
    d for d in os.listdir(APPS)
    if d != "base" and os.path.isdir(os.path.join(APPS, d))
) if os.path.isdir(APPS) else []

missing, stale = [], []

def require(kind, name, where):
    """Must appear somewhere in the docs, generated inventory included."""
    if name and name not in docs:
        missing.append(f"COVERAGE  {kind} not documented: {name}  ({where})")

def require_by_hand(kind, name, where):
    """Must appear in a hand-maintained doc. Satisfying this from the
    generated inventory would be circular, so the inventory is excluded."""
    if name and name not in hand:
        missing.append(
            f"COVERAGE  {kind} not described in the diagrams, architecture.md "
            f"or README: {name}  ({where})")

# --- clusters, domains, CIDRs, Talos nodes -----------------------------------
for loc in LOCATIONS:
    require_by_hand("location", loc, "kubernetes/apps/")
    settings = os.path.join(root, "clusters", f"talos-{loc}", "flux", "vars",
                            "cluster-settings.yaml")
    if os.path.isfile(settings):
        txt = open(settings, encoding="utf-8").read()
        for key in ("CLUSTER_NAME", "CLUSTER_DOMAIN", "CLUSTER_POD_CIDR",
                    "CLUSTER_SERVICE_CIDR", "CLUSTER_LOAD_BALANCER_CIDR",
                    "LAN_CIDR", "KUBERNETES_API_VIP"):
            m = re.search(rf"^\s*{key}:\s*\"?([^\"\s#]+)", txt, re.M)
            if m:
                require_by_hand(f"{loc} {key}", m.group(1),
                                settings.replace(root + "/", ""))

    tal = os.path.join(root, "clusters", f"talos-{loc}", "bootstrap", "talos",
                       "talconfig.yaml")
    if os.path.isfile(tal):
        txt = open(tal, encoding="utf-8").read()
        for host in re.findall(r"^\s*-?\s*hostname:\s*\"?([A-Za-z0-9][\w.-]*)",
                               txt, re.M):
            require_by_hand(f"{loc} node", host, tal.replace(root + "/", ""))

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
    for doc in re.split(r"^---\s*$", text, flags=re.M):
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

deployed = set()
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
                    deployed.add(name)
                    require(f"{loc} app", name, rel)

# --- reverse direction: a diagram must not name an app that is gone ----------
# Two ways to declare that a diagram names an app: the historical `app_<id>`
# node-id prefix, or an explicit `// diagram-apps:` comment, which is what the
# current diagrams use because their labels are prose.
declared = {}
for p in dot_paths:
    rel = p.replace(root + "/", "")
    text = open(p, encoding="utf-8").read()
    for line in re.findall(r"^\s*//\s*diagram-apps:\s*(.+)$", text, re.M):
        for name in re.split(r"[,\s]+", line.strip()):
            if name:
                declared.setdefault(name, rel)
    for ident in set(re.findall(r'\bapp_([A-Za-z0-9][\w.-]*)\b', text)):
        declared.setdefault(ident.replace("_", "-"), rel)

for name, rel in sorted(declared.items()):
    if name not in deployed:
        stale.append(f"COVERAGE  {rel} names an app that is not deployed: {name}")

for line in sorted(set(missing)) + sorted(set(stale)):
    print(line)
sys.exit(1 if (missing or stale) else 0)
PY

# ---------------------------------------------------------------- links
# A diagram nobody links to is a diagram nobody maintains, and a link to a
# diagram that no longer exists is a broken README. Only meaningful for the
# real docs/diagrams/ set, so skip when specific files were passed in.
if [ "$#" -eq 0 ] && [ -f "$ROOT/README.md" ]; then
  python3 - "$ROOT" <<'PY' || rc=1
import os, re, sys
root = sys.argv[1]
readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
diagdir = os.path.join(root, "docs", "diagrams")

on_disk = {f for f in os.listdir(diagdir) if f.endswith(".svg")} \
    if os.path.isdir(diagdir) else set()
linked = set(re.findall(r"docs/diagrams/([A-Za-z0-9._-]+\.svg)", readme))

bad = []
for f in sorted(on_disk - linked):
    bad.append(f"LINKS     docs/diagrams/{f} exists but the README never links it")
for f in sorted(linked - on_disk):
    bad.append(f"LINKS     README links docs/diagrams/{f}, which does not exist")
for line in bad:
    print(line)
sys.exit(1 if bad else 0)
PY
fi

if [ "$rc" = 0 ]; then
  printf '✓ diagram OK: %s source file(s) (syntax=%s)\n' "${#SOURCES[@]}" "$engine"
fi
exit "$rc"
