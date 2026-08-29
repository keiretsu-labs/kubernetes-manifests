#!/usr/bin/env bash
# tools/gen-inventory.sh — generate docs/reference/inventory.md from the tree.
#
# The inventory (every cluster, Talos machine, namespace and Flux Kustomization)
# used to be hand-drawn inside the README's architecture graph, where it was
# ~280 lines of boxes wired together with invisible edges and went stale the
# moment anyone added an app. Deriving it from disk instead makes drift
# impossible rather than merely detectable, and leaves the diagram free to show
# mechanism instead of doubling as a list.
#
# Reads, per location under kubernetes/apps/:
#   clusters/talos-<loc>/flux/vars/cluster-settings.yaml    cluster facts
#   clusters/talos-<loc>/bootstrap/talos/talconfig.yaml     machines + versions
#   kubernetes/apps/<loc>/<ns>/*.yaml                       Flux Kustomizations
#
# Deliberately NOT emitted: install-disk serials (they identify physical
# hardware and tools/check-diagram.sh rejects them), and anything live.
#
# Usage:
#   tools/gen-inventory.sh            # write docs/reference/inventory.md
#   tools/gen-inventory.sh --check    # exit 1 if the committed file is stale
#   tools/gen-inventory.sh -          # write to stdout
#
# Exit 0 = up to date / written, 1 = stale (--check), 2 = bad usage.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/reference/inventory.md"

mode="write"
case "${1:-}" in
  "")        ;;
  --check)   mode="check" ;;
  -)         mode="stdout" ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *)         echo "gen-inventory.sh: unknown argument: $1" >&2; exit 2 ;;
esac

gen() {
  python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
APPS = os.path.join(root, "kubernetes", "apps")

try:
    import yaml
except ImportError:
    yaml = None

# ------------------------------------------------------------------ helpers
def settings(loc):
    """cluster-settings ConfigMap data as a plain dict."""
    p = os.path.join(root, "clusters", f"talos-{loc}", "flux", "vars",
                     "cluster-settings.yaml")
    if not os.path.isfile(p):
        return {}
    txt = open(p, encoding="utf-8").read()
    if yaml is not None:
        try:
            doc = yaml.safe_load(txt)
            if isinstance(doc, dict) and isinstance(doc.get("data"), dict):
                return {k: str(v).strip() for k, v in doc["data"].items()}
        except Exception:
            pass
    out = {}
    for m in re.finditer(r"^\s{2,}([A-Z][A-Z0-9_]*):\s*\"?([^\"\n#]*?)\"?\s*$",
                         txt, re.M):
        out[m.group(1)] = m.group(2).strip()
    return out


def talconfig(loc):
    p = os.path.join(root, "clusters", f"talos-{loc}", "bootstrap", "talos",
                     "talconfig.yaml")
    if not os.path.isfile(p):
        return {}
    txt = open(p, encoding="utf-8").read()
    if yaml is not None:
        try:
            doc = yaml.safe_load(txt)
            if isinstance(doc, dict):
                return doc
        except Exception:
            pass
    # Minimal fallback: enough for the node roster and versions.
    doc = {"nodes": []}
    for key in ("clusterName", "talosVersion", "kubernetesVersion"):
        m = re.search(rf"^{key}:\s*\"?([^\"\s#]+)", txt, re.M)
        if m:
            doc[key] = m.group(1)
    for block in re.split(r"^\s*-\s+hostname:", txt, flags=re.M)[1:]:
        host = re.match(r'\s*"?([\w.-]+)', block)
        if not host:
            continue
        cp = re.search(r"^\s+controlPlane:\s*(true|false)", block, re.M)
        doc["nodes"].append({
            "hostname": host.group(1),
            "controlPlane": bool(cp and cp.group(1) == "true"),
        })
    return doc


KUSTOMIZATION_API = re.compile(r"kustomize\.toolkit\.fluxcd\.io/v1")
META_NAME = re.compile(
    r"^metadata:\s*$(?:\n(?:[ \t]+.*)?$)*?\n[ \t]+name:[ \t]*(?:&\S+[ \t]+)?[\"']?"
    r"([A-Za-z0-9][\w.-]*)", re.M)


TARGET_NS = re.compile(r"^\s+targetNamespace:\s*[\"']?([A-Za-z0-9][\w.-]*)", re.M)


def kustomization_names(text):
    """(name, targetNamespace) for each Flux Kustomization in a YAML string.

    Pointer files carry several kinds (Kustomization, GitRepository, Receiver,
    Secret). Only the Flux Kustomization names are app identities, so parse
    per-document rather than grepping `name:` — a nested sourceRef or
    substitute name would otherwise masquerade as an app.

    targetNamespace is where the objects actually land, which is NOT always the
    directory the pointer sits in. Reporting only the directory would send
    someone running kubectl to the wrong namespace, so the exceptions get their
    own table per cluster.
    """
    out = []
    for doc in re.split(r"^---\s*$", text, flags=re.M):
        if not KUSTOMIZATION_API.search(doc):
            continue
        if not re.search(r"^\s*kind:\s*Kustomization\s*$", doc, re.M):
            continue
        name = target = None
        parsed = False
        if yaml is not None:
            try:
                obj = yaml.safe_load(doc)
            except Exception:
                obj = None
            if isinstance(obj, dict):
                parsed = True
                n = (obj.get("metadata") or {}).get("name")
                if isinstance(n, str) and n:
                    name = n
                t = (obj.get("spec") or {}).get("targetNamespace")
                if isinstance(t, str) and t:
                    target = t
        if name is None:
            m = META_NAME.search(doc)
            if m:
                name = m.group(1)
        if name is None:
            continue
        # Only fall back to the regex when the document did not parse. A parsed
        # document that has no spec.targetNamespace genuinely has none, whereas
        # the regex would happily match the word somewhere else in the file —
        # inside a `patches:` block, for instance — and invent a namespace.
        if target is None and not parsed:
            m = TARGET_NS.search(doc)
            if m:
                target = m.group(1)
        out.append((name, target))
    return out


def commented_out(text):
    """True when a pointer file has no live YAML left — every line is a
    comment or blank. Such a pointer renders to nothing but still sits in the
    kustomization, so the inventory says so instead of silently dropping it."""
    for ln in text.splitlines():
        s = ln.strip()
        if s and not s.startswith("#"):
            return False
    return True


# Namespace -> the role it plays, so the tables can be scanned by function the
# way the old hand-drawn diagram's panels could be. Anything unlisted falls
# through to "Application workloads": a new namespace is therefore always
# reported, just possibly under the wrong heading, which is a far cheaper
# failure than silently omitting it.
ROLES = [
    ("Delivery and platform control", {
        "flux-system", "kro-system", "tuppr"}),
    ("Node runtime, scheduling and sandboxing", {
        "kube-system", "spegel", "node-feature-discovery", "vpa-system",
        "gvisor", "kata-containers", "agent-sandbox-system", "arc-systems",
        "default"}),
    ("Networking, ingress and identity", {
        "envoy-gateway-system", "cloudflare", "k8gb", "home", "tailscale",
        "tailscale-system", "tailscale-examples", "auth",
        "lan", "hubble-ui", "tinyauth-egress"}),
    ("Storage and data services", {
        "rook-ceph", "csi-addons", "csi-driver-smb", "local-path-storage",
        "snapshot-controller", "garage", "garage-operator-system",
        "cnpg-system", "dragonfly-operator-system", "velero", "zot",
        "strimzi"}),
    ("Observability", {
        "monitoring", "mimir", "victoria-logs", "fluent-bit", "gatus", "monz",
        "opencost"}),
    ("Certificates and secrets", {
        "cert-manager", "external-secrets"}),
    ("Fleet management", {
        "open-cluster-management", "open-cluster-management-agent"}),
    ("GPU, RDMA and inference", {
        "k8s-gpu-dra-driver", "gpu-operator", "ai", "rdma-shared-dp",
        "lws-system"}),
]
DEFAULT_ROLE = "Application workloads"
ROLE_ORDER = [name for name, _ in ROLES] + [DEFAULT_ROLE]


def role_of(ns):
    for name, members in ROLES:
        if ns in members:
            return name
    return DEFAULT_ROLE


def apps_by_namespace(loc):
    """{directory: ([live app names], [parked pointers], {app: target ns})}"""
    locdir = os.path.join(APPS, loc)
    result = {}
    if not os.path.isdir(locdir):
        return result
    for ns in sorted(os.listdir(locdir)):
        nsdir = os.path.join(locdir, ns)
        if not os.path.isdir(nsdir):
            continue
        live, parked, targets = [], [], {}
        for dirpath, _, files in os.walk(nsdir):
            for fn in sorted(files):
                if not fn.endswith((".yaml", ".yml")):
                    continue
                if fn in ("kustomization.yaml", "namespace.yaml"):
                    continue
                try:
                    txt = open(os.path.join(dirpath, fn), encoding="utf-8").read()
                except OSError:
                    continue
                found = kustomization_names(txt)
                if found:
                    for name, target in found:
                        live.append(name)
                        if target and target != ns:
                            targets[name] = target
                elif commented_out(txt):
                    parked.append(fn[:-5] if fn.endswith(".yaml") else fn)
        result[ns] = (sorted(set(live)), sorted(set(parked)), targets)
    return result


LOCATIONS = sorted(
    d for d in os.listdir(APPS)
    if d != "base" and os.path.isdir(os.path.join(APPS, d))
) if os.path.isdir(APPS) else []

# ------------------------------------------------------------------ emit
w = sys.stdout.write

w("<!-- Generated by tools/gen-inventory.sh. Do not edit by hand. -->\n")
w("# Deployment inventory\n\n")
w("Every cluster, Talos machine, pointer directory and Flux Kustomization in\n"
  "this repository, derived from the tree itself by `tools/gen-inventory.sh`. An\n"
  "app appears here because a pointer file exists for it under\n"
  "`kubernetes/apps/<location>/`, which is what makes it deployed at all — so\n"
  "this file cannot disagree with the repository.\n\n"
  "One distinction worth reading carefully: the *pointer directory* is where the\n"
  "Flux Kustomization file lives in this repo. It is usually also the namespace\n"
  "the objects land in, but not always — a pointer can set `targetNamespace`.\n"
  "Where the two differ the row shows `→ ns <name>`, and each cluster gets a\n"
  "table of the exceptions.\n\n")
w("Regenerate after adding or removing an app:\n\n")
w("```bash\ntools/gen-inventory.sh\n```\n\n")
w("`tools/check-diagram.sh` fails when the committed copy is out of date. For\n"
  "the reasoning behind any of these components see\n"
  "[the architecture reference](architecture.md); for the picture, see the\n"
  "diagram in the [README](../../README.md#architecture).\n\n")

# Totals first, so the file opens with the shape of the estate.
totals = []
for loc in LOCATIONS:
    ns_map = apps_by_namespace(loc)
    n_apps = sum(len(v[0]) for v in ns_map.values())
    tc = talconfig(loc)
    totals.append((loc, len(tc.get("nodes") or []), len(ns_map), n_apps))

w("## At a glance\n\n")
w("| Location | Talos machines | Pointer directories | Flux Kustomizations |\n")
w("|---|---:|---:|---:|\n")
for loc, nodes, nss, apps in totals:
    w(f"| `{loc}` | {nodes} | {nss} | {apps} |\n")
w(f"| **total** | **{sum(t[1] for t in totals)}** "
  f"| **{sum(t[2] for t in totals)}** "
  f"| **{sum(t[3] for t in totals)}** |\n\n")

FACT_KEYS = [
    ("CLUSTER_NAME", "Cluster name"),
    ("CLUSTER_DISPLAY_NAME", "Display name"),
    ("LOCATION", "`${LOCATION}`"),
    ("SITE_ID", "`${SITE_ID}`"),
    ("CLUSTER_DOMAIN", "`${CLUSTER_DOMAIN}`"),
    ("FAILOVER", "Failover target"),
    ("TIMEZONE", "Timezone"),
    ("LAN_CIDR", "LAN CIDR"),
    ("KUBERNETES_API_VIP", "Kubernetes API VIP"),
    ("CLUSTER_POD_CIDR", "Pod CIDR"),
    ("CLUSTER_SERVICE_CIDR", "Service CIDR"),
    ("CLUSTER_LOAD_BALANCER_CIDR", "LoadBalancer CIDR"),
    ("STORAGECLASS_DEFAULT", "Default StorageClass"),
    ("STORAGECLASS_METADATA", "Metadata StorageClass"),
    ("STORAGECLASS_LONGTERM", "Long-term StorageClass"),
]

for loc in LOCATIONS:
    st = settings(loc)
    tc = talconfig(loc)
    ns_map = apps_by_namespace(loc)

    title = st.get("CLUSTER_DISPLAY_NAME") or loc
    w(f"## {title} — `talos-{loc}`\n\n")

    w("| Setting | Value |\n|---|---|\n")
    for key, label in FACT_KEYS:
        if st.get(key):
            w(f"| {label} | `{st[key]}` |\n")
    for key, label in (("clusterName", "Talos cluster name"),
                       ("talosVersion", "Talos version"),
                       ("kubernetesVersion", "Kubernetes version")):
        if tc.get(key):
            w(f"| {label} | `{tc[key]}` |\n")
    sid = st.get("SITE_ID")
    if sid:
        w(f"| Tailscale 4via6 range | `fd7a:115c:a1e0:b1a:0:{sid}::/96` |\n")
    w("\n")

    nodes = tc.get("nodes") or []
    if nodes:
        w("| Machine | Role | Address |\n|---|---|---|\n")
        for n in nodes:
            host = n.get("hostname", "?")
            role = "control plane" if n.get("controlPlane") else "worker"
            addr = n.get("ipAddress") or "—"
            labels = n.get("nodeLabels") or {}
            if labels:
                role += " · " + ", ".join(
                    f"`{k}={v}`" for k, v in sorted(labels.items()))
            w(f"| `{host}` | {role} | `{addr}` |\n")
        w("\n")

    w("| Role | Pointer directory | Flux Kustomizations |\n|---|---|---|\n")
    for role in ROLE_ORDER:
        for ns in sorted(n for n in ns_map if role_of(n) == role):
            live, parked, targets = ns_map[ns]
            cells = [f"`{a}`" + (f" → ns `{targets[a]}`" if a in targets
                                 else "")
                     for a in live]
            cells += [f"`{p}` (pointer commented out — renders to nothing)"
                      for p in parked]
            w(f"| {role} | `{ns}` | "
              f"{', '.join(cells) if cells else '—'} |\n")
    w("\n")

    # The directory a pointer lives in is usually also the namespace its
    # objects land in — but not always, and guessing wrong sends you to
    # kubectl with the wrong -n. Call out every exception explicitly.
    moved = sorted(
        (app, ns, targets[app])
        for ns, (_, _, targets) in ns_map.items()
        for app in targets)
    if moved:
        w("Pointers whose objects land outside their directory's namespace "
          "— use the right-hand column with `kubectl -n`:\n\n")
        w("| Flux Kustomization | Pointer directory | Actual namespace |\n")
        w("|---|---|---|\n")
        for app, ns, target in moved:
            w(f"| `{app}` | `{ns}` | `{target}` |\n")
        w("\n")
PY
}

# Compare and diff in python: this repo's containers do not reliably ship
# cmp(1) or diff(1), but python3 is already required to generate at all.
same() { python3 -c 'import sys;a=open(sys.argv[1],"rb").read();b=open(sys.argv[2],"rb").read();sys.exit(0 if a==b else 1)' "$1" "$2"; }
show_diff() {
  python3 - "$1" "$2" <<'PY'
import difflib, sys
have = open(sys.argv[1], encoding="utf-8").read().splitlines()
want = open(sys.argv[2], encoding="utf-8").read().splitlines()
for i, line in enumerate(difflib.unified_diff(
        have, want, "committed", "generated", lineterm="", n=1)):
    if i >= 40:
        print("          ... (truncated)")
        break
    print("          " + line)
PY
}

case "$mode" in
  stdout) gen ;;
  write)
    mkdir -p "$(dirname "$OUT")"
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    gen >"$tmp" || { echo "gen-inventory.sh: generation failed" >&2; exit 2; }
    [ -s "$tmp" ] || { echo "gen-inventory.sh: generated nothing" >&2; exit 2; }
    if [ -f "$OUT" ] && same "$tmp" "$OUT"; then
      printf '✓ inventory already current: %s\n' "${OUT#"$ROOT"/}"
    else
      cat "$tmp" >"$OUT"
      printf '✓ wrote %s\n' "${OUT#"$ROOT"/}"
    fi
    ;;
  check)
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    gen >"$tmp" || { echo "gen-inventory.sh: generation failed" >&2; exit 2; }
    if [ ! -f "$OUT" ]; then
      echo "STALE     docs/reference/inventory.md is missing — run tools/gen-inventory.sh" >&2
      exit 1
    fi
    if ! same "$tmp" "$OUT"; then
      echo "STALE     docs/reference/inventory.md does not match the tree — run tools/gen-inventory.sh" >&2
      show_diff "$OUT" "$tmp" >&2
      exit 1
    fi
    printf '✓ inventory current: %s\n' "${OUT#"$ROOT"/}"
    ;;
esac
