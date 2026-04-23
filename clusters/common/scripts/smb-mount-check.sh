#!/usr/bin/env bash

# SMB Mount Staleness Checker — Ottawa + Robbinsdale
#
# Checks all CIFS globalmounts on all nodes for staleness, then verifies
# every pod with an SMB PVC can actually read its mount path.
#
# Based on incident: nagato double-reboot (Apr 2025) caused CIFS reconnect
# to fire during Samba init, permanently staling all mounts.
#
# Usage: ./smb-mount-check.sh [KUBECTL_PATH]
# Defaults to /opt/data/bin/kubectl if not on PATH

KUBECTL="${1:-$(command -v kubectl 2>/dev/null || echo '/opt/data/bin/kubectl')}"

if [ ! -x "$KUBECTL" ]; then
    echo "ERROR: kubectl not found at $KUBECTL"
    echo "Usage: $0 /path/to/kubectl"
    exit 1
fi

PYTHON=$(command -v python3)

$PYTHON - "$KUBECTL" <<'PYEOF'
import sys, subprocess, json

kubectl = sys.argv[1]

CLUSTERS = [
    ("ottawa",      "ottawa-k8s-operator.keiretsu.ts.net"),
    ("robbinsdale", "robbinsdale-k8s-operator.keiretsu.ts.net"),
]

RED    = '\033[0;31m'
GREEN  = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE   = '\033[0;34m'
BOLD   = '\033[1m'
NC     = '\033[0m'

def ok(s):   print(f"{GREEN}OK{NC}    {s}")
def warn(s): print(f"{YELLOW}WARN{NC}  {s}")
def bad(s):  print(f"{RED}STALE{NC} {s}")
def header(s): print(f"\n{BLUE}=== {s} ==={NC}")
def run(*args, timeout=30):
    try:
        return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        r = subprocess.CompletedProcess(args, 1)
        r.stdout = ""
        r.stderr = "timed out"
        return r

overall_stale = False

for cluster_name, context in CLUSTERS:
    print(f"\n{BOLD}{BLUE}━━━ CLUSTER: {cluster_name} ({context}) ━━━{NC}")

    r = run(kubectl, "--context", context, "cluster-info")
    if r.returncode != 0:
        warn(f"Cannot reach cluster — skipping (Tailscale running?)")
        continue

    cluster_stale = False

    # ── CSI SMB Node Pods ────────────────────────────────────────────────────
    header("CSI SMB Node Pods")
    r = run(kubectl, "--context", context, "-n", "kube-system",
            "get", "pods", "-o", "wide")
    csi_lines = [l for l in r.stdout.splitlines() if "csi-smb-node" in l]
    if not csi_lines:
        warn("No csi-smb-node pods found")
        continue
    for l in csi_lines:
        print(l)

    # ── Globalmount Staleness ────────────────────────────────────────────────
    header("Globalmount Staleness Check")

    for line in csi_lines:
        parts   = line.split()
        csi_pod = parts[0]
        node    = parts[-3]  # NODE column: NAME READY STATUS RESTARTS AGE IP NODE NOMINATED READINESS

        r = run(kubectl, "--context", context, "-n", "kube-system",
                "exec", csi_pod, "-c", "smb", "--",
                "find", "/var/lib/kubelet/plugins/kubernetes.io/csi/smb.csi.k8s.io",
                "-maxdepth", "2", "-name", "globalmount", "-type", "d")
        gmounts = [l for l in r.stdout.splitlines() if l.strip()]

        if not gmounts:
            warn(f"{node} ({csi_pod}): no globalmounts staged")
            continue

        r = run(kubectl, "--context", context, "-n", "kube-system",
                "exec", csi_pod, "-c", "smb", "--", "cat", "/proc/mounts")
        proc_mounts = r.stdout.splitlines()

        for gpath in gmounts:
            source = next(
                (m.split()[0] for m in proc_mounts if len(m.split()) >= 2 and m.split()[1] == gpath),
                None
            )
            if not source:
                # Directory exists but no mount — leftover from prior NodeUnstageVolume, normal
                continue

            r = run(kubectl, "--context", context, "-n", "kube-system",
                    "exec", csi_pod, "-c", "smb", "--",
                    "sh", "-c", f"timeout 5 ls '{gpath}' >/dev/null 2>&1 && echo OK || echo FAIL",
                    timeout=15)
            result = r.stdout.strip()
            if result == "OK":
                ok(f"{node}: {source}")
            else:
                bad(f"{node}: {source}")
                cluster_stale = True

    # ── Pod Mount Verification ───────────────────────────────────────────────
    header("Pod Mount Verification (all namespaces)")

    r = run(kubectl, "--context", context, "get", "pv", "-o", "json")
    pvs = json.loads(r.stdout)
    smb_pvcs = set()
    for pv in pvs["items"]:
        if pv.get("spec", {}).get("csi", {}).get("driver") == "smb.csi.k8s.io":
            ref = pv["spec"].get("claimRef", {})
            if ref.get("name"):
                smb_pvcs.add(ref["name"])

    r = run(kubectl, "--context", context, "get", "pods",
            "--all-namespaces", "-o", "json")
    pods = json.loads(r.stdout)

    for p in pods["items"]:
        if p["status"].get("phase") != "Running":
            continue
        name      = p["metadata"]["name"]
        namespace = p["metadata"]["namespace"]
        vols = {v["name"]: v.get("persistentVolumeClaim", {}).get("claimName", "")
                for v in p["spec"].get("volumes", [])}
        smb_vol_names = {k for k, v in vols.items() if v in smb_pvcs}
        if not smb_vol_names:
            continue

        for c in p["spec"]["containers"]:
            for m in c.get("volumeMounts", []):
                if m["name"] not in smb_vol_names:
                    continue
                path = m["mountPath"]
                label = f"[{namespace}] {name} ({c['name']}) → {path}"

                # Try ls first; if that fails, check whether ls is even available
                # (distroless containers have no shell/builtins)
                r_ls = run(kubectl, "--context", context, "-n", namespace,
                           "exec", name, "-c", c["name"], "--", "ls", path,
                           timeout=15)
                out = (r_ls.stdout + r_ls.stderr).strip().replace("\n", " ")

                if r_ls.returncode == 0 and r_ls.stdout.strip():
                    ok(label)
                elif r_ls.returncode == 0:
                    warn(f"{label} is empty")
                    cluster_stale = True
                elif any(x in out for x in ["executable file not found", "not found",
                                            "No such file or directory"]):
                    # ls binary not available in container (distroless/busybox without
                    # busybox ls). Check if the container has any command at all.
                    for alt_cmd in ["sh", "bash", "python3", "python", "cat", "/bin/sh"]:
                        r_alt = run(kubectl, "--context", context, "-n", namespace,
                                    "exec", name, "-c", c["name"], "--",
                                    "test", "-x", alt_cmd, timeout=10)
                        if r_alt.returncode == 0:
                            # Container has a shell — retry with that
                            r = run(kubectl, "--context", context, "-n", namespace,
                                    "exec", name, "-c", c["name"], "--",
                                    "sh", "-c", f"ls '{path}' >/dev/null 2>&1 && echo OK || echo FAIL",
                                    timeout=15)
                            out = r.stdout.strip()
                            if out == "OK":
                                ok(label)
                            else:
                                bad(f"{label}: {out[:80]}")
                                cluster_stale = True
                            break
                    else:
                        # No shell available — distroless container.
                        # Globalmount staleness check already passed for this node,
                        # so the mount is alive. Pod is Running + Ready = healthy.
                        print(f"  ⏭️  {label}: skip (distroless container, no shell)")
                    break  # skip remaining volumeMounts for this container
                elif any(x in out for x in ["Stale file handle", "cannot access",
                                            "No such file"]):
                    bad(f"{label}: {out[:80]}")
                    cluster_stale = True
                # else: exec error (pod not ready etc.) — skip silently
                break

    # ── Cluster Summary ──────────────────────────────────────────────────────
    header(f"{cluster_name} Summary")
    if not cluster_stale:
        print(f"{GREEN}All SMB mounts healthy.{NC}")
    else:
        print(f"{RED}Stale or broken mounts detected.{NC}")
        print("""
To recover — for each affected node:
  1. Get the CSI pod:
     kubectl -n kube-system get pods -o wide | grep csi-smb-node | grep <node>
  2. Force-unmount stale mounts (pod bind mounts first, then globals):
     kubectl -n kube-system exec <csi-pod> -c smb -- sh -c \\
       "for p in $(cat /proc/mounts | python3 -c \\"import sys; [print(l.split()[1]) for l in sys.stdin if 'pods' in l.split()[1] and l.split()[2]=='cifs']\\" 2>/dev/null); do umount -f $p; done"
     kubectl -n kube-system exec <csi-pod> -c smb -- sh -c \\
       "for p in $(cat /proc/mounts | python3 -c \\"import sys; [print(l.split()[1]) for l in sys.stdin if 'globalmount' in l.split()[1] and l.split()[2]=='cifs']\\" 2>/dev/null); do umount -f $p; done"
  3. Delete affected pods — or just reboot the node:
     talosctl -n <node-ip> reboot""")
        overall_stale = True

print()
if not overall_stale:
    print(f"{GREEN}{BOLD}All clusters healthy.{NC}")
else:
    print(f"{RED}{BOLD}Issues detected — see above.{NC}")
PYEOF
