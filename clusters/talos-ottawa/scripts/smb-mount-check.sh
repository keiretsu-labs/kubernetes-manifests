#!/usr/bin/env zsh

# SMB Mount Staleness Checker
# Checks all CIFS globalmounts on Ottawa nodes for staleness and reports
# which pods are affected. Does NOT auto-fix — outputs what needs to be done.
#
# Based on incident: nagato double-reboot (Apr 2025) caused CIFS reconnect
# to fire during Samba init, permanently staling all mounts on rei/asuka/kaji.
#
# Usage:
#   ./smb-mount-check.sh
#   SMB_KUBE_CONTEXT=my-context ./smb-mount-check.sh

CONTEXT="${SMB_KUBE_CONTEXT:-ottawa-k8s-operator.keiretsu.ts.net}"
NAMESPACE="media"
NAS_IP="192.168.169.111"
KUBECTL=$(command -v kubectl)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() { print "\n${BLUE}=== $1 ===${NC}" }
print_ok()     { print "${GREEN}OK${NC}    $1" }
print_warn()   { print "${YELLOW}WARN${NC}  $1" }
print_bad()    { print "${RED}STALE${NC} $1" }

any_stale=0

# ── CSI Node Pods ──────────────────────────────────────────────────────────────
print_header "CSI SMB Node Pods"
$KUBECTL --context $CONTEXT -n kube-system get pods -o wide | grep csi-smb-node

# ── Globalmount Staleness ──────────────────────────────────────────────────────
print_header "Globalmount Staleness Check"

for node in rei asuka kaji; do
    csi_pod=$($KUBECTL --context $CONTEXT -n kube-system get pods -o wide 2>/dev/null \
        | awk "/csi-smb-node.*$node/ {print \$1}")

    if [[ -z "$csi_pod" ]]; then
        print_warn "$node: no csi-smb-node pod found"
        any_stale=1
        continue
    fi

    # maxdepth 2 avoids descending INTO stale globalmount dirs
    mounts=$($KUBECTL --context $CONTEXT -n kube-system exec $csi_pod -c smb -- \
        sh -c "find /var/lib/kubelet/plugins/kubernetes.io/csi/smb.csi.k8s.io \
               -maxdepth 2 -name globalmount -type d 2>/dev/null" 2>/dev/null)

    if [[ -z "$mounts" ]]; then
        print_warn "$node ($csi_pod): no globalmounts found (volumes not staged)"
        any_stale=1
        continue
    fi

    while IFS= read -r gpath; do
        source=$($KUBECTL --context $CONTEXT -n kube-system exec $csi_pod -c smb -- \
            sh -c "awk '\$2==\"$gpath\" {print \$1}' /proc/mounts" 2>/dev/null | tr -d '[:space:]')

        if [[ -z "$source" ]]; then
            print_warn "$node: $gpath exists but not mounted"
            any_stale=1
            continue
        fi

        # timeout guards against blocking on reconnecting mounts
        result=$($KUBECTL --context $CONTEXT -n kube-system exec $csi_pod -c smb -- \
            sh -c "timeout 5 ls '$gpath' >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null | tr -d '[:space:]')

        if [[ "$result" = "OK" ]]; then
            print_ok "$node: $source"
        else
            print_bad "$node: $source"
            any_stale=1
        fi
    done <<< "$mounts"
done

# ── Pod Mount Verification ─────────────────────────────────────────────────────
print_header "Pod Mount Verification"

pod_results=$(python3 -c "
import json, sys, subprocess

kubectl = '$KUBECTL'
context = '$CONTEXT'
namespace = '$NAMESPACE'
smb_pvcs = {'media-share', 'qbittorrent-downloads', 'media-share-robbinsdale'}

r = subprocess.run([kubectl, '--context', context, '-n', namespace, 'get', 'pods', '-o', 'json'],
                   capture_output=True, text=True, timeout=30)
pods = json.loads(r.stdout)

for p in pods['items']:
    if p['status'].get('phase') != 'Running':
        continue
    name = p['metadata']['name']
    vols = {v['name']: v.get('persistentVolumeClaim', {}).get('claimName', '')
            for v in p['spec'].get('volumes', [])}
    smb_vol_names = {k for k, v in vols.items() if v in smb_pvcs}
    if not smb_vol_names:
        continue
    for c in p['spec']['containers']:
        for m in c.get('volumeMounts', []):
            if m['name'] in smb_vol_names:
                path = m['mountPath']
                r = subprocess.run(
                    [kubectl, '--context', context, '-n', namespace,
                     'exec', name, '-c', c['name'], '--', 'ls', path],
                    capture_output=True, text=True, timeout=15
                )
                out = (r.stdout + r.stderr).strip().replace('\n', ' ')
                if r.returncode == 0 and r.stdout.strip():
                    print(f'OK|{name}|{c[\"name\"]}|{path}')
                elif r.returncode == 0:
                    print(f'EMPTY|{name}|{c[\"name\"]}|{path}')
                else:
                    print(f'BAD|{name}|{c[\"name\"]}|{path}|{out[:80]}')
                break
")

while IFS='|' read -r mstatus pod container path extra; do
    case $mstatus in
        OK)    print_ok "$pod ($container) → $path" ;;
        EMPTY) print_warn "$pod ($container) → $path is empty"; any_stale=1 ;;
        BAD)   print_bad "$pod ($container) → $path: $extra"; any_stale=1 ;;
    esac
done <<< "$pod_results"

# ── Summary ────────────────────────────────────────────────────────────────────
print_header "Summary"

if [[ $any_stale -eq 0 ]]; then
    print "${GREEN}All SMB mounts healthy.${NC}"
else
    print "${RED}Stale or broken mounts detected.${NC}"
    print ""
    print "Recovery options (least to most disruptive):"
    print ""
    print "  1. Force-unmount and delete affected pods (per node):"
    print "     CSI_POD=\$($KUBECTL --context $CONTEXT -n kube-system get pods -o wide | awk '/csi-smb-node.*<node>/ {print \$1}')"
    print "     $KUBECTL --context $CONTEXT -n kube-system exec \$CSI_POD -c smb -- sh -c \\"
    print "       \"for p in \\\$(awk '\\\$1~/$NAS_IP/ && \\\$2~/pods/ {print \\\$2}' /proc/mounts); do umount -f \\\$p; done\""
    print "     $KUBECTL --context $CONTEXT -n kube-system exec \$CSI_POD -c smb -- sh -c \\"
    print "       \"for p in \\\$(awk '\\\$1~/$NAS_IP/ && \\\$2~/globalmount/ {print \\\$2}' /proc/mounts); do umount -f \\\$p; done\""
    print "     # Then delete affected pods to trigger fresh NodeStageVolume"
    print ""
    print "  2. Reboot the node (cleanest fix):"
    print "     talosctl -n <node-ip> reboot"
    print "     Node IPs: rei=192.168.169.118  asuka=192.168.169.117  kaji=192.168.169.119"
fi
