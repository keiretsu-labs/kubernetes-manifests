#!/usr/bin/env bash

# Ceph OSD BlueStore Slow Ops Diagnostic Script
# Identifies which PVCs and workloads are causing OSD slow operations
# by correlating OSD latency, NVMe disk utilization, and per-volume IO
#
# Environment Variables:
#   KUBE_CONTEXT   - Kubernetes context. If not set, uses current context (e.g. from kubeswitch).
#   PROMETHEUS_URL - Prometheus base URL (required, no default)
#   CEPH_NAMESPACE - Rook-Ceph namespace (default: rook-ceph)
#   LOG_FILE       - Path to log file. If set, output goes to both stdout and the file.
#   RATE_WINDOW    - Prometheus rate window (default: 5m)

set -o pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
Ceph OSD BlueStore Slow Ops Diagnostic
=======================================
Identifies which PVCs and workloads are causing OSD slow operations
by correlating OSD latency, NVMe disk utilization, and per-volume IO.

Usage:
  PROMETHEUS_URL=<url> ./ceph-osd-slow-ops-diag.sh

Examples:
  PROMETHEUS_URL=https://prometheus.example.com ./ceph-osd-slow-ops-diag.sh
  PROMETHEUS_URL=https://prometheus.example.com KUBE_CONTEXT=my-cluster ./ceph-osd-slow-ops-diag.sh
  PROMETHEUS_URL=https://prometheus.example.com LOG_FILE=/tmp/diag.log ./ceph-osd-slow-ops-diag.sh

Prerequisites:
  - Rook-Ceph must be deployed in the cluster (default namespace: rook-ceph, override with CEPH_NAMESPACE)
  - The Ceph toolbox pod must be running (deploy/rook-ceph-tools)
    See: https://rook.io/docs/rook/latest/Troubleshooting/ceph-toolbox/
  - Prometheus must be accessible from where you run this script

Environment Variables:
  PROMETHEUS_URL  (required)  Prometheus base URL for PromQL queries
  KUBE_CONTEXT    (optional)  Kubernetes context override. If not set, uses current context (e.g. from kubeswitch)
  LOG_FILE        (optional)  Path to log file. Output goes to both stdout and the file (ANSI stripped)
  CEPH_NAMESPACE  (optional)  Rook-Ceph namespace, default: rook-ceph
  RATE_WINDOW     (optional)  Prometheus rate() window, default: 5m
USAGE
}

if [[ "${1:-}" = "-h" || "${1:-}" = "--help" ]]; then
    usage
    exit 0
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
PROMETHEUS_URL="${PROMETHEUS_URL:-}"
CEPH_NAMESPACE="${CEPH_NAMESPACE:-rook-ceph}"
CEPH_TOOLS_DEPLOY="deploy/rook-ceph-tools"
RATE_WINDOW="${RATE_WINDOW:-5m}"

if [[ -z "$PROMETHEUS_URL" ]]; then
    usage >&2
    echo "" >&2
    echo "ERROR: PROMETHEUS_URL is required." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
USE_COLOR=false
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    USE_COLOR=true
fi

if $USE_COLOR; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# ---------------------------------------------------------------------------
# Logging - strip ANSI codes from log file, keep colors on terminal
# ---------------------------------------------------------------------------
LOG_ACTIVE=false
if [[ -n "${LOG_FILE:-}" ]]; then
    LOG_ACTIVE=true
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' | grep -v '^\s*\.\.\. ' >> "$LOG_FILE"))
fi

# ---------------------------------------------------------------------------
# Globals populated by diagnostic functions
# ---------------------------------------------------------------------------
SLOW_OSDS_SPACE=""
DISK_OCC=""
declare -gA NODE_TO_IP
PV_MAP=""
AFFECTED_NODES=""
OSD_PERF_RAW=""
SUMMARY_ROWS=""
NODE_NVME_UTIL=""
SLOW_OP_THRESHOLD=""
SLOW_OP_LIFETIME=""
SLOW_OP_COUNT_THRESHOLD=""
SLOW_KV_COUNTS=""

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
kc() {
    if [[ -n "$KUBE_CONTEXT" ]]; then
        kubectl --context "$KUBE_CONTEXT" "$@"
    else
        kubectl "$@"
    fi
}

ceph_cmd() {
    kc exec -n "$CEPH_NAMESPACE" "$CEPH_TOOLS_DEPLOY" -- "$@"
}

prom_query() {
    local result
    result=$(curl -s --connect-timeout 10 "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=$1" 2>&1) || {
        echo '{"status":"error","data":{"result":[]}}' ; return 0
    }
    echo "$result"
}

progress() {
    [[ -t 2 ]] && echo -ne "  ${CYAN}...${NC} $1\r" >&2
}

clear_progress() {
    [[ -t 2 ]] && printf "\r%-70s\r" "" >&2
}

section_header() {
    local num="$1" total="$2" title="$3"
    echo ""
    echo -e "${BOLD}${BLUE}[$num/$total] $title${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

die() { echo -e "${RED}FATAL${NC}: $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Ceph Health & Affected OSDs
# ---------------------------------------------------------------------------
check_ceph_health() {
    section_header 1 8 "Ceph Health & Affected OSDs"

    progress "Querying ceph health..."
    HEALTH_DETAIL=$(ceph_cmd ceph health detail 2>&1) || die "Failed to exec into ceph toolbox. Is the pod running?\n  Check: kubectl -n $CEPH_NAMESPACE get $CEPH_TOOLS_DEPLOY"
    clear_progress

    echo "$HEALTH_DETAIL" | head -1

    SLOW_OSDS=$(echo "$HEALTH_DETAIL" | grep "observed slow operation" | sed 's/.*osd\.\([0-9]*\).*/\1/' | sort -n || true)

    if [[ -z "$SLOW_OSDS" ]]; then
        echo -e "${GREEN}✓${NC} No OSDs reporting BlueStore slow operations"
        echo -e "${GREEN}  Cluster is healthy. Nothing to diagnose.${NC}"
        exit 0
    fi

    SLOW_OSDS_SPACE=$(echo "$SLOW_OSDS" | tr '\n' ' ')
    echo -e "${YELLOW}⚠${NC} Affected OSDs: $SLOW_OSDS_SPACE"

    progress "Querying alert thresholds..."
    SLOW_OP_THRESHOLD=$(ceph_cmd ceph config get osd bluestore_kv_sync_util_logging_s 2>/dev/null || echo "10")
    SLOW_OP_COUNT_THRESHOLD=$(ceph_cmd ceph config get osd bluestore_slow_ops_warn_threshold 2>/dev/null || echo "1")
    SLOW_OP_LIFETIME=$(ceph_cmd ceph config get osd bluestore_slow_ops_warn_lifetime 2>/dev/null || echo "86400")
    clear_progress

    echo -e "  ${BOLD}Alert config:${NC}"
    echo -e "    bluestore_kv_sync_util_logging_s  = ${YELLOW}${SLOW_OP_THRESHOLD}${NC}"
    echo -e "    bluestore_slow_ops_warn_threshold = ${YELLOW}${SLOW_OP_COUNT_THRESHOLD}${NC}"
    echo -e "    bluestore_slow_ops_warn_lifetime  = ${YELLOW}${SLOW_OP_LIFETIME}${NC}"
    local lifetime_h
    lifetime_h=$(python3 -c "print(f'{int(${SLOW_OP_LIFETIME})/3600:.0f}')")
    local threshold_clean
    threshold_clean=$(python3 -c "print(f'{float(\"${SLOW_OP_THRESHOLD}\"):.0f}')")
    echo -e "  Meaning: warning fires when >=${SLOW_OP_COUNT_THRESHOLD} op(s) exceed ${threshold_clean}s within ${lifetime_h}h"
}

# ---------------------------------------------------------------------------
# 2. OSD Topology & Disk Mapping
# ---------------------------------------------------------------------------
build_node_map() {
    section_header 2 8 "OSD Topology & Disk Mapping"

    progress "Fetching node list..."
    local node_output
    node_output=$(kc get nodes -o wide --no-headers 2>&1) || die "Cannot list nodes. Check kubectl access."
    clear_progress

    while IFS= read -r line; do
        local n ip
        n=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | awk '{print $6}')
        if [[ -n "$n" && -n "$ip" ]]; then
            NODE_TO_IP[$n]=$ip
        fi
    done <<< "$node_output"

    progress "Querying OSD disk occupation..."
    DISK_OCC=$(prom_query 'ceph_disk_occupation')
    clear_progress

    local cf="0"; $USE_COLOR && cf="1"

    printf "  %-8s %-8s %-12s\n" "OSD" "Node" "Device"
    printf "  %-8s %-8s %-12s\n" "---" "----" "------"
    echo "$DISK_OCC" | python3 -c "
import json, sys
data = json.load(sys.stdin)
slow = set(sys.argv[1].split())
uc = sys.argv[2] == '1'
Y = '\033[1;33m' if uc else ''
N = '\033[0m' if uc else ''
if data.get('status') == 'success':
    for r in sorted(data['data']['result'], key=lambda x: int(x['metric'].get('ceph_daemon','osd.99').replace('osd.',''))):
        m = r['metric']
        d = m.get('ceph_daemon',''); osd = d.replace('osd.','')
        h = m.get('exported_instance', m.get('instance','?'))
        dev = m.get('device','?')
        if osd in slow:
            print(f'  {Y}{d:<8s} {h:<8s} {dev:<12s} <-- SLOW{N}')
        else:
            print(f'  {d:<8s} {h:<8s} {dev:<12s}')
" "$SLOW_OSDS_SPACE" "$cf"
}

# ---------------------------------------------------------------------------
# 3. OSD Performance
# ---------------------------------------------------------------------------
check_osd_performance() {
    section_header 3 8 "OSD Performance (Latency & Throughput)"

    progress "Querying OSD perf..."
    OSD_PERF_RAW=$(ceph_cmd ceph osd perf 2>&1) || { echo -e "  ${RED}ERROR${NC}: ceph osd perf failed"; return 0; }
    local write_tp write_ops slow_kv_json
    write_tp=$(prom_query "rate(ceph_osd_op_w_in_bytes[$RATE_WINDOW])")
    write_ops=$(prom_query "rate(ceph_osd_op_w[$RATE_WINDOW])")
    slow_kv_json=$(prom_query "increase(ceph_bluestore_slow_committed_kv_count[${SLOW_OP_LIFETIME:-86400}s])")
    clear_progress

    SLOW_KV_COUNTS="$slow_kv_json"

    local cf="0"; $USE_COLOR && cf="1"

    local lifetime_label
    lifetime_label=$(python3 -c "print(f'{int(${SLOW_OP_LIFETIME:-86400})/3600:.0f}h')")
    printf "  %-8s %14s  %14s  %10s  %11s  %12s\n" "OSD" "Commit Lat(ms)" "Apply Lat(ms)" "Write MB/s" "Write Ops/s" "SlowKV(${lifetime_label})"
    printf "  %-8s %14s  %14s  %10s  %11s  %12s\n" "---" "--------------" "--------------" "----------" "-----------" "------------"

    python3 -c "
import json, sys
slow = set(sys.argv[1].split()); uc = sys.argv[6] == '1'
Y = '\033[1;33m' if uc else ''; N = '\033[0m' if uc else ''
perf = {}
for ln in sys.argv[2].strip().split('\n'):
    p = ln.split()
    if len(p) >= 3 and p[0].isdigit(): perf[p[0]] = (p[1], p[2])
tp = {}
for r in json.loads(sys.argv[3]).get('data',{}).get('result',[]):
    tp[r['metric'].get('ceph_daemon','').replace('osd.','')] = float(r['value'][1])/1024/1024
ops = {}
for r in json.loads(sys.argv[4]).get('data',{}).get('result',[]):
    ops[r['metric'].get('ceph_daemon','').replace('osd.','')] = float(r['value'][1])
kv = {}
for r in json.loads(sys.argv[5]).get('data',{}).get('result',[]):
    kv[r['metric'].get('ceph_daemon','').replace('osd.','')] = int(float(r['value'][1]))
for oid in sorted(perf, key=int):
    c, a = perf[oid]; t = tp.get(oid,0); o = ops.get(oid,0)
    k = kv.get(oid, 0)
    if oid in slow:
        print(f'  {Y}osd.{oid:<4s} {c:>14s}  {a:>14s}  {t:>10.2f}  {o:>11.1f}  {k:>12d}{N}')
    else:
        print(f'  osd.{oid:<4s} {c:>14s}  {a:>14s}  {t:>10.2f}  {o:>11.1f}  {k:>12d}')
" "$SLOW_OSDS_SPACE" "$OSD_PERF_RAW" "$write_tp" "$write_ops" "$slow_kv_json" "$cf"

    echo ""
    echo -e "  Highlighted rows = OSDs flagged in ${BOLD}ceph health detail${NC}"
    echo -e "  ${BOLD}SlowKV(${lifetime_label})${NC} = KV commits exceeding ${SLOW_OP_THRESHOLD:-10}s in the last ${lifetime_label} (matches warning window)"
}

# ---------------------------------------------------------------------------
# 4. NVMe / OSD Disk Utilization Per Node
# ---------------------------------------------------------------------------
check_disk_utilization() {
    section_header 4 8 "NVMe / OSD Disk Utilization Per Node"

    local cf="0"; $USE_COLOR && cf="1"
    local node ip
    for node in "${!NODE_TO_IP[@]}"; do
        ip="${NODE_TO_IP[$node]}"
        progress "Querying disk util for $node..."
        local util_json
        util_json=$(prom_query "rate(node_disk_io_time_seconds_total{instance=~\"${ip}.*\",device=~\"nvme.*|dm-.*\"}[$RATE_WINDOW]) * 100")
        clear_progress

        echo -e "  ${BOLD}$node${NC} ($ip):"
        echo "$util_json" | python3 -c "
import json, sys
data = json.load(sys.stdin); uc = sys.argv[1] == '1'
if data.get('status') == 'success':
    res = sorted([(r['metric'].get('device','?'), float(r['value'][1])) for r in data['data']['result']],
                 key=lambda x: (0 if x[0].startswith('nvme') else 1, x[0]))
    for dev, val in res:
        if val > 75:   c, s = ('\033[0;31m' if uc else ''), 'HIGH'
        elif val > 50: c, s = ('\033[1;33m' if uc else ''), 'ELEVATED'
        else:          c, s = ('\033[0;32m' if uc else ''), 'OK'
        n = '\033[0m' if uc else ''
        print(f'    {dev:<10s} {c}{val:>5.1f}%{n} {c}{s}{n}')
" "$cf"
        echo

        local max_nvme
        max_nvme=$(echo "$util_json" | python3 -c "
import json, sys
data = json.load(sys.stdin); mx = 0
if data.get('status') == 'success':
    for r in data['data']['result']:
        if r['metric'].get('device','').startswith('nvme'):
            v = float(r['value'][1])
            if v > mx: mx = v
print(f'{mx:.1f}')")
        NODE_NVME_UTIL+="${node}	${max_nvme}"$'\n'
    done
}

# ---------------------------------------------------------------------------
# 5. Top Workload IO on Affected Nodes
# ---------------------------------------------------------------------------
check_workload_io() {
    section_header 5 8 "Top Workload IO on Affected Nodes (RBD Volumes)"

    AFFECTED_NODES=$(echo "$DISK_OCC" | python3 -c "
import json, sys
data = json.load(sys.stdin); slow = set(sys.argv[1].split()); nodes = set()
if data.get('status') == 'success':
    for r in data['data']['result']:
        m = r['metric']; osd = m.get('ceph_daemon','').replace('osd.','')
        if osd in slow: nodes.add(m.get('exported_instance', m.get('instance','')))
print(' '.join(nodes))
" "$SLOW_OSDS_SPACE")

    progress "Fetching PV map..."
    PV_MAP=$(kc get pv -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pv in data['items']:
    csi = pv.get('spec',{}).get('csi',{})
    img = csi.get('volumeAttributes',{}).get('imageName','')
    cl = pv.get('spec',{}).get('claimRef',{})
    if img and cl.get('name',''):
        print(f'{img}|{cl[\"namespace\"]}/{cl[\"name\"]}')
" || echo "")
    clear_progress

    local cf="0"; $USE_COLOR && cf="1"

    local node ip
    for node in "${!NODE_TO_IP[@]}"; do
        ip="${NODE_TO_IP[$node]}"
        if [[ "$AFFECTED_NODES" != *"$node"* ]]; then continue; fi

        echo -e "  ${BOLD}$node${NC} ($ip):"

        progress "Listing RBD devices on $node..."
        local osd_pod rbd_list
        osd_pod=$(kc get pods -n "$CEPH_NAMESPACE" -l app=rook-ceph-osd \
            --field-selector spec.nodeName="$node" -o name 2>/dev/null | head -1)
        rbd_list=""
        if [[ -n "$osd_pod" ]]; then
            rbd_list=$(kc exec -n "$CEPH_NAMESPACE" "$osd_pod" -c osd -- rbd device list --format json 2>/dev/null || true)
        fi
        if [[ -z "$rbd_list" || "$rbd_list" = "[]" ]]; then
            local csi_pod
            csi_pod=$(kc get pods -n "$CEPH_NAMESPACE" -l app=csi-rbdplugin \
                --field-selector spec.nodeName="$node" -o name 2>/dev/null | head -1)
            if [[ -n "$csi_pod" ]]; then
                rbd_list=$(kc exec -n "$CEPH_NAMESPACE" "$csi_pod" -c csi-rbdplugin -- rbd device list --format json 2>/dev/null || true)
            fi
        fi
        clear_progress

        progress "Querying RBD metrics for $node..."
        local rbd_iops rbd_util rbd_write
        rbd_iops=$(prom_query "rate(node_disk_writes_completed_total{instance=~\"${ip}.*\",device=~\"rbd.*\"}[$RATE_WINDOW])")
        rbd_util=$(prom_query "rate(node_disk_io_time_seconds_total{instance=~\"${ip}.*\",device=~\"rbd.*\"}[$RATE_WINDOW]) * 100")
        rbd_write=$(prom_query "rate(node_disk_written_bytes_total{instance=~\"${ip}.*\",device=~\"rbd.*\"}[$RATE_WINDOW])")
        clear_progress

        progress "Fetching pods on $node..."
        local pods_json
        pods_json=$(kc get pods -A -o json --field-selector spec.nodeName="$node" 2>/dev/null || echo '{"items":[]}')
        clear_progress

        python3 -c "
import json, sys

rbd_raw    = sys.argv[1]; iops_d = json.loads(sys.argv[2])
util_d     = json.loads(sys.argv[3]); write_d = json.loads(sys.argv[4])
pv_raw     = sys.argv[5]; uc = sys.argv[6] == '1'

img2pvc = {}
for ln in pv_raw.strip().split('\n'):
    if '|' in ln: i, p = ln.split('|',1); img2pvc[i] = p

dev2img = {}
try:
    for entry in json.loads(rbd_raw):
        im = entry.get('name', '')
        dv = entry.get('device', '')
        if im and dv:
            dev2img[dv.replace('/dev/', '')] = im
except (json.JSONDecodeError, TypeError):
    pass

def mmap(d):
    o = {}
    if d.get('status')=='success':
        for r in d['data']['result']: o[r['metric'].get('device','')] = float(r['value'][1])
    return o

iops, util, wbps = mmap(iops_d), mmap(util_d), mmap(write_d)
combined = []
for dev in set(list(iops)+list(util)+list(wbps)):
    i, u, w = iops.get(dev,0), util.get(dev,0), wbps.get(dev,0)
    im = dev2img.get(dev,''); pvc = img2pvc.get(im,'')
    label = pvc if pvc else (im if im else dev)
    if i > 0.1 or u > 1: combined.append((dev, label, i, u, w))
combined.sort(key=lambda x: x[2], reverse=True)

if combined:
    print(f'    {\"Device\":<8s} {\"Wr IOPS\":>8s} {\"Disk Util\":>10s} {\"Wr MB/s\":>8s}  PVC')
    print(f'    {\"------\":<8s} {\"-------\":>8s} {\"----------\":>10s} {\"-------\":>8s}  ---')
    for dev, label, i, u, w in combined:
        if uc:
            if u > 50:   c = '\033[0;31m'
            elif u > 20: c = '\033[1;33m'
            else:        c = '\033[0;32m'
            n = '\033[0m'
        else: c = n = ''
        print(f'    {dev:<8s} {i:>8.1f} {c}{u:>9.1f}%{n} {w/1024/1024:>8.2f}  {label}')
else:
    print('    No significant RBD IO detected')
" "$rbd_list" "$rbd_iops" "$rbd_util" "$rbd_write" "$PV_MAP" "$cf"

        local node_rows
        node_rows=$(printf '%s\0%s\0%s\0%s\0%s\0%s\0%s' \
            "$node" "$rbd_list" "$rbd_iops" "$rbd_util" "$rbd_write" "$PV_MAP" "$pods_json" | \
            python3 -c "
import json, sys
parts = sys.stdin.buffer.read().split(b'\x00')
node = parts[0].decode(); rbd_raw = parts[1].decode()
iops_d = json.loads(parts[2]); util_d = json.loads(parts[3])
write_d = json.loads(parts[4]); pv_raw = parts[5].decode()
pods = json.loads(parts[6])

img2pvc = {}
for ln in pv_raw.strip().split('\n'):
    if '|' in ln: i, p = ln.split('|',1); img2pvc[i] = p

dev2img = {}
try:
    for entry in json.loads(rbd_raw):
        im = entry.get('name', '')
        dv = entry.get('device', '')
        if im and dv:
            dev2img[dv.replace('/dev/', '')] = im
except (json.JSONDecodeError, TypeError):
    pass

def mmap(d):
    o = {}
    if d.get('status')=='success':
        for r in d['data']['result']: o[r['metric'].get('device','')] = float(r['value'][1])
    return o

iops, util, wbps = mmap(iops_d), mmap(util_d), mmap(write_d)

pvc2pod = {}
for pod in pods.get('items',[]):
    ns = pod['metadata']['namespace']; pn = pod['metadata']['name']
    for v in pod['spec'].get('volumes',[]):
        if 'persistentVolumeClaim' in v:
            pvc2pod[ns+'/'+v['persistentVolumeClaim']['claimName']] = ns+'/'+pn

for dev in set(list(iops)+list(util)+list(wbps)):
    i, u, w = iops.get(dev,0), util.get(dev,0), wbps.get(dev,0)
    if i < 0.1 and u < 1: continue
    im = dev2img.get(dev,''); pvc = img2pvc.get(im,'')
    pod = pvc2pod.get(pvc,'')
    if not pvc: pvc = im if im else dev
    if not pod: pod = '<unmapped>'
    print(f'{node}\t{pod}\t{pvc}\t{i:.1f}\t{u:.1f}\t{w/1024/1024:.2f}')
")

        if [[ -n "$node_rows" ]]; then
            SUMMARY_ROWS+="$node_rows"$'\n'
        fi
        echo
    done
}

# ---------------------------------------------------------------------------
# 6. PVC -> Workload Mapping
# ---------------------------------------------------------------------------
show_pvc_workload_map() {
    section_header 6 8 "PVC -> Workload Mapping (Affected Nodes)"

    local node ip
    for node in "${!NODE_TO_IP[@]}"; do
        ip="${NODE_TO_IP[$node]}"
        if [[ "$AFFECTED_NODES" != *"$node"* ]]; then continue; fi

        echo -e "  ${BOLD}$node${NC} - Pods with PVCs:"

        progress "Listing pods on $node..."
        kc get pods -A -o json --field-selector spec.nodeName="$node" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pod in sorted(data['items'], key=lambda p: p['metadata']['namespace']+'/'+p['metadata']['name']):
    ns = pod['metadata']['namespace']; name = pod['metadata']['name']
    pvcs = [v['persistentVolumeClaim']['claimName'] for v in pod['spec'].get('volumes',[]) if 'persistentVolumeClaim' in v]
    if pvcs:
        print(f'    {ns}/{name}')
        for p in pvcs: print(f'      PVC: {p}')
"
        clear_progress
        echo
    done
}

# ---------------------------------------------------------------------------
# 7. Pool-Level IO Summary
# ---------------------------------------------------------------------------
show_pool_io() {
    section_header 7 8 "Pool-Level IO Summary"

    progress "Querying pool stats..."
    local pool_stats
    pool_stats=$(ceph_cmd ceph osd pool stats 2>&1) || { echo -e "  ${RED}ERROR${NC}: pool stats failed"; return 0; }
    clear_progress

    echo "$pool_stats" | while IFS= read -r line; do
        if [[ "$line" == pool* ]]; then echo -e "  ${BOLD}$line${NC}"
        elif [[ "$line" == *"nothing is going on"* ]]; then continue
        elif [[ -n "$line" ]]; then echo "    $line"
        fi
    done
}

# ---------------------------------------------------------------------------
# 8. CORRELATION SUMMARY TABLE
# ---------------------------------------------------------------------------
show_summary_table() {
    echo ""
    echo ""
    local lifetime_h
    lifetime_h=$(python3 -c "print(f'{int(${SLOW_OP_LIFETIME:-86400})/3600:.0f}h')")

    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  SLOW OSD ROOT CAUSE CORRELATION${NC}"
    local threshold_clean2
    threshold_clean2=$(python3 -c "print(f'{float(\"${SLOW_OP_THRESHOLD:-10}\"):.0f}')")
    echo -e "  bluestore_kv_sync_util_logging_s=${YELLOW}${threshold_clean2}${NC}  bluestore_slow_ops_warn_threshold=${YELLOW}${SLOW_OP_COUNT_THRESHOLD:-1}${NC}  bluestore_slow_ops_warn_lifetime=${YELLOW}${SLOW_OP_LIFETIME:-86400}${NC} (${lifetime_h})"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [[ -z "$SUMMARY_ROWS" ]]; then
        echo -e "  ${YELLOW}No workload IO data collected for affected nodes.${NC}"
        return 0
    fi

    local cf="0"; $USE_COLOR && cf="1"

    echo "$SUMMARY_ROWS" | python3 -c "
import json, sys

lines     = sys.stdin.read().strip()
disk_occ  = json.loads(sys.argv[1])
slow_osds = set(sys.argv[2].split())
perf_raw  = sys.argv[3]
uc        = sys.argv[4] == '1'
nvme_raw  = sys.argv[5]
kv_data   = json.loads(sys.argv[6])

if uc:
    R, G, Y, C, B, N = '\033[0;31m', '\033[0;32m', '\033[1;33m', '\033[0;36m', '\033[1m', '\033[0m'
    RBOLD = '\033[1;31m'
else:
    R = G = Y = C = B = N = RBOLD = ''

node_nvme = {}
for ln in nvme_raw.strip().split('\n'):
    if '\t' in ln:
        n, v = ln.split('\t', 1)
        node_nvme[n] = float(v)

osd_kv = {}
if kv_data.get('status') == 'success':
    for r in kv_data['data']['result']:
        osd_kv[r['metric'].get('ceph_daemon','').replace('osd.','')] = int(float(r['value'][1]))

node2osds = {}
if disk_occ.get('status') == 'success':
    for r in disk_occ['data']['result']:
        m = r['metric']; osd = m.get('ceph_daemon','').replace('osd.','')
        host = m.get('exported_instance', m.get('instance',''))
        if osd in slow_osds:
            node2osds.setdefault(host, []).append(osd)
for k in node2osds:
    node2osds[k] = sorted(node2osds[k], key=int)

osd_lat = {}
for ln in perf_raw.strip().split('\n'):
    pp = ln.split()
    if len(pp) >= 3 and pp[0].isdigit():
        osd_lat[pp[0]] = int(pp[1])

rows = []
for ln in lines.split('\n'):
    if not ln.strip(): continue
    pp = ln.split('\t')
    if len(pp) >= 6:
        node, pod, pvc, iops, util, wr = pp[0], pp[1], pp[2], float(pp[3]), float(pp[4]), float(pp[5])
        rows.append((node, pod, pvc, iops, util, wr))

rows.sort(key=lambda x: (x[0], -x[3]))

OC = 20
print()
hdr = f'  {B}{\"HOST\":<7s} {\"SLOW OSDs\":<{OC}s} {\"Lat(ms)\":>8s} {\"SlowKV\":>7s} {\"NVMe\":>6s}  {\"NAMESPACE/POD\":<43s} {\"PVC\":<32s} {\"WR IOPS\":>8s} {\"DISK %\":>8s}{N}'
print(hdr)
sep = f'  {\"─\"*7} {\"─\"*OC} {\"─\"*8} {\"─\"*7} {\"─\"*6}  {\"─\"*43} {\"─\"*32} {\"─\"*8} {\"─\"*8}'
print(sep)

prev_node = ''
for node, pod, pvc, iops, util, wr in rows:
    osds = node2osds.get(node, [])
    max_lat = max((osd_lat.get(o, 0) for o in osds), default=0)
    total_kv = sum(osd_kv.get(o, 0) for o in osds)
    osd_str = 'osd.' + ','.join(osds) if osds else '-'

    if node == prev_node:
        node_disp = ''
        osd_disp = ''
        lat_disp = f'{\"\":>8s}'
        kv_disp = f'{\"\":>7s}'
        nvme_disp = f'{\"\":>6s}'
    else:
        node_disp = node
        osd_disp = osd_str
        lat_disp = f'{max_lat:>8d}'
        kv_disp = f'{Y}{total_kv:>7d}{N}' if total_kv > 0 else f'{total_kv:>7d}'
        nv = node_nvme.get(node, 0)
        if nv > 75: nc = RBOLD
        elif nv > 50: nc = Y
        else: nc = Y
        nvme_disp = f'{nc}{nv:>5.0f}%{N}'
    prev_node = node

    if '/' in pvc:
        pvc_disp = pvc.split('/', 1)[1]
    else:
        pvc_disp = pvc

    pod_disp = pod if pod != '?' else '<unmapped>'
    pod_disp = pod_disp[:43] if len(pod_disp) <= 43 else pod_disp[:40] + '...'
    pvc_disp = pvc_disp[:32] if len(pvc_disp) <= 32 else pvc_disp[:29] + '...'

    if iops >= 10:
        clr = RBOLD
        tag = ' !!!'
    elif iops >= 2:
        clr = Y
        tag = ''
    else:
        clr = Y
        tag = ''

    print(f'  {clr}{node_disp:<7s} {osd_disp:<{OC}s}{N} {lat_disp} {kv_disp} {nvme_disp}  {clr}{pod_disp:<43s} {pvc_disp:<32s} {iops:>8.1f} {util:>7.1f}%{tag}{N}')

print()
print(f'  {RBOLD}!!!{N} = heavy writer (>=10 IOPS)    {Y}yellow{N} = on node with slow OSDs')
print(f'  Lat(ms) = avg OSD commit latency    SlowKV = KV ops exceeding threshold in warning window')
print()
" "$DISK_OCC" "$SLOW_OSDS_SPACE" "$OSD_PERF_RAW" "$cf" "$NODE_NVME_UTIL" "$SLOW_KV_COUNTS"
}

# ---------------------------------------------------------------------------
# Footer
# ---------------------------------------------------------------------------
show_footer() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}Diagnostic Complete${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${BOLD}Common Remedies:${NC}"
    echo "  - Spread write-heavy workloads (marked !!!) across nodes to distribute IO"
    echo "  - Tune database WAL settings (PostgreSQL: wal_compression, larger wal_buffers)"
    echo "  - Reduce write-amplification (PG autoscaler, compression, larger WAL buffers)"
    echo "  - Adjust Ceph BlueStore throttle (bluestore_throttle_bytes, bluestore_throttle_deferred_bytes)"
    echo ""
    if $LOG_ACTIVE; then
        echo "Log saved to: $LOG_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}Ceph OSD BlueStore Slow Ops Diagnostic${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  $(date +'%Y-%m-%d %H:%M:%S %Z')                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    local active_ctx="${KUBE_CONTEXT:-$(kubectl config current-context 2>/dev/null || echo 'unknown')}"
    echo -e "  Context: ${BOLD}$active_ctx${NC}"
    echo -e "  Prometheus: ${BOLD}$PROMETHEUS_URL${NC}"

    progress "Checking prerequisites..."
    if ! kc get namespace "$CEPH_NAMESPACE" &>/dev/null; then
        clear_progress
        die "Namespace '$CEPH_NAMESPACE' not found. Is Rook-Ceph deployed in this cluster?"
    fi
    if ! kc get -n "$CEPH_NAMESPACE" "$CEPH_TOOLS_DEPLOY" &>/dev/null; then
        clear_progress
        die "Ceph toolbox not found ($CEPH_TOOLS_DEPLOY in $CEPH_NAMESPACE).
  Deploy it first: https://rook.io/docs/rook/latest/Troubleshooting/ceph-toolbox/"
    fi
    clear_progress
    echo -e "  Toolbox: ${GREEN}found${NC} ($CEPH_TOOLS_DEPLOY)"

    check_ceph_health
    build_node_map
    check_osd_performance
    check_disk_utilization
    check_workload_io
    show_pvc_workload_map
    show_pool_io
    show_summary_table
    show_footer
}

main "$@"
