#!/usr/bin/env bash
# tools/ktriage.sh — compact, read-only pod triage. Replaces a 200-800 line
# `kubectl get pod -o yaml` dump with the few things worth reading: status,
# container/init states, non-True conditions, the latest events, and a short
# log tail (plus a previous-log tail for restarted containers).
#
# All Kubernetes access goes through tools/kc.sh; only read-only get/logs verbs
# are ever issued (a closed set — this cannot exec/apply/delete/patch). Bounds
# are enforced locally with tail/cut, so oversized server output can't blow up
# the summary even if kubectl ignores --tail. macOS bash 3.2 clean; no jq /
# python / full YAML/JSON.
#
# Exit: 2 = usage / bad cluster (a bad alias inherits kc.sh's exit 2). If the
# initial pod read fails, nothing else is printed and its kubectl exit code is
# propagated. 4 = the pod read succeeded but one or more later sections
# (states / conditions / events / current logs) were unavailable — each is
# marked inline and the useful output is still emitted first. 0 = all read.
#
# Usage:
#   tools/ktriage.sh <ot|rb|sp> <namespace> <pod>
#   tools/ktriage.sh ot media immich-server-0
set -u
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KC="$DIR/kc.sh"

usage() {
  cat >&2 <<EOF
usage: ${0##*/} <ot|rb|sp> <namespace> <pod>
example: ${0##*/} ot media immich-server-0
EOF
}

[ $# -eq 3 ] || { usage; exit 2; }
cluster="$1"; ns="$2"; pod="$3"

# Every call: routed through kc.sh (cluster->context) with a fail-fast timeout.
kc() { "$KC" "$cluster" --request-timeout=10s "$@"; }

# Set to 4 the moment a section fails *after* the pod-read gate, so a transient
# API/timeout error is never silently rendered as an empty/"(none)" section.
degraded=0

# jsonpath row for a *ContainerStatuses list: 6 tab-separated fields ->
# name  ready  restarts  waiting/terminated-reason  running-startedAt  message
state_jsonpath() {
  printf '%s' '{range '"$1"'[*]}{.name}{"\t"}{.ready}{"\t"}{.restartCount}{"\t"}{.state.waiting.reason}{.state.terminated.reason}{"\t"}{.state.running.startedAt}{"\t"}{.state.waiting.message}{.state.terminated.message}{"\n"}{end}'
}

# ---- summary (also the existence / API gate) -----------------------------
summary="$(kc -n "$ns" get pod "$pod" \
  -o custom-columns=PHASE:.status.phase,NODE:.spec.nodeName,PODIP:.status.podIP,START:.status.startTime \
  --no-headers 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'ktriage: cannot read pod %s/%s on %s (kubectl exit %s)\n' "$ns" "$pod" "$cluster" "$rc" >&2
  printf '%s\n' "$summary" | head -3 | cut -c1-160 >&2
  exit "$rc"
fi
# Parse the data row (last non-blank line) so a kubectl stderr warning folded
# in by the 2>&1 above can't be misread as the pod's fields.
read -r phase node ip start <<EOF
$(printf '%s\n' "$summary" | grep -v '^[[:space:]]*$' | tail -1)
EOF
printf '# pod %s/%s @ %s\n' "$ns" "$pod" "$cluster"
printf 'PHASE=%s NODE=%s IP=%s START=%s\n' "${phase:-?}" "${node:-?}" "${ip:-?}" "${start:-?}"

# ---- container + init states ---------------------------------------------
# Regular containers first (their names/restart counts drive the log section);
# init containers after, display-only.
names=(); rests=()
print_states() {  # $1=label  $2=jsonpath-root  $3=collect(1/0)
  local label="$1" root="$2" collect="$3" out rc name ready rest reason running msg
  out="$(kc -n "$ns" get pod "$pod" -o jsonpath="$(state_jsonpath "$root")" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: (unavailable: kubectl exit %s)\n' "$label" "$rc"; degraded=4; return 0
  fi
  [ -n "$out" ] || return 0
  printf '%s:\n' "$label"
  while IFS=$'\t' read -r name ready rest reason running msg; do
    # A real *ContainerStatuses row always carries a boolean ready field; any
    # other line is a wrapped fragment of a multi-line container message — skip
    # it so it can't print a junk row or be fetched as a phantom container.
    case "$ready" in true|false) ;; *) continue ;; esac
    [ -n "$name" ] || continue
    [ -n "$reason" ] || { [ -n "$running" ] && reason="Running"; }
    [ -n "$reason" ] || reason="?"
    if [ -n "$msg" ]; then
      printf '  %s ready=%s restarts=%s %s — %s\n' \
        "$name" "$ready" "$rest" "$reason" "$(printf '%s' "$msg" | cut -c1-140)"
    else
      printf '  %s ready=%s restarts=%s %s\n' "$name" "$ready" "$rest" "$reason"
    fi
    if [ "$collect" = 1 ]; then
      case "$rest" in ''|*[!0-9]*) rest=0 ;; esac
      names+=("$name"); rests+=("$rest")
    fi
  done <<EOF
$out
EOF
}
print_states "containers"      ".status.containerStatuses"      1
print_states "init containers" ".status.initContainerStatuses"  0

# ---- non-True conditions -------------------------------------------------
cond="$(kc -n "$ns" get pod "$pod" \
  -o jsonpath='{range .status.conditions[?(@.status!="True")]}{.type}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' \
  2>/dev/null)"; crc=$?
if [ "$crc" -ne 0 ]; then
  printf 'conditions: (unavailable: kubectl exit %s)\n' "$crc"; degraded=4
elif [ -n "$cond" ]; then
  printf 'conditions (not True):\n'
  while IFS=$'\t' read -r ctype creason cmsg; do
    [ -n "$ctype" ] || continue
    if [ -n "$cmsg" ]; then
      printf '  %s %s %s\n' "$ctype" "${creason:-?}" "$(printf '%s' "$cmsg" | cut -c1-140)"
    else
      printf '  %s %s\n' "$ctype" "${creason:-?}"
    fi
  done <<EOF
$cond
EOF
fi

# ---- events (latest 10) --------------------------------------------------
ev="$(kc -n "$ns" get events \
  --field-selector "involvedObject.name=$pod" --sort-by=.lastTimestamp \
  -o custom-columns=LAST:.lastTimestamp,TYPE:.type,REASON:.reason,MSG:.message \
  --no-headers 2>/dev/null)"; erc=$?
printf 'events (latest 10):\n'
if [ "$erc" -ne 0 ]; then
  printf '  (unavailable: kubectl exit %s)\n' "$erc"; degraded=4
elif [ -n "$ev" ]; then
  printf '%s\n' "$ev" | tail -10 | cut -c1-160 | sed 's/^/  /'
else
  printf '  (none)\n'
fi

# ---- logs (tail 20 per container; previous only when restarted) ----------
emit_log() {  # $1=container  $2=label  $3=previous-flag-or-empty
  local ctr="$1" label="$2" prev="$3" log lrc
  if [ -n "$prev" ]; then
    log="$(kc -n "$ns" logs "$pod" -c "$ctr" "$prev" --tail=20 2>&1)"; lrc=$?
  else
    log="$(kc -n "$ns" logs "$pod" -c "$ctr" --tail=20 2>&1)"; lrc=$?
  fi
  printf '  %s (%s, tail 20):\n' "$ctr" "$label"
  if [ "$lrc" -ne 0 ]; then
    printf '    (no %s logs: %s)\n' "$label" "$(printf '%s' "$log" | head -1 | cut -c1-140)"
    # A missing *current* log is a real read failure; a missing *previous* log
    # (rotated/GC'd) is expected for a restarted container, so don't degrade on it.
    [ "$label" = current ] && degraded=4
    return 0
  fi
  [ -n "$log" ] || { printf '    (no output)\n'; return 0; }
  printf '%s\n' "$log" | tail -20 | cut -c1-200 | sed 's/^/    /'
}

printf 'logs:\n'
if [ "${#names[@]}" -eq 0 ]; then
  printf '  (no containers)\n'
fi
i=0
while [ "$i" -lt "${#names[@]}" ]; do
  emit_log "${names[$i]}" current ""
  [ "${rests[$i]}" -gt 0 ] && emit_log "${names[$i]}" previous --previous
  i=$((i + 1))
done

exit "$degraded"
