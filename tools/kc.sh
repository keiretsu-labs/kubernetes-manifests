#!/usr/bin/env bash
# tools/kc.sh — kubectl wrapper: repo-root kubeconfig + short cluster aliases.
# Kills the per-call KUBECONFIG export + full --context retype. Works from any
# cwd (anchored to the script's own location, not $PWD), execs kubectl so args
# and exit code pass straight through.
#
# Usage:
#   tools/kc.sh <cluster> [kubectl args...]
#   tools/kc.sh ot -n media get pods
#   tools/kc.sh rb get ns
#   tools/kc.sh sp get nodes
#
# Clusters:
#   ot | ottawa        repo .kube/config, context ottawa-k8s-operator.keiretsu.ts.net
#   rb | robbinsdale   repo .kube/config, context robbinsdale-k8s-operator.keiretsu.ts.net
#   sp | stpetersburg  ~/.kube/stpetersburg (no --context)
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<EOF
usage: ${0##*/} <cluster> [kubectl args...]
clusters:
  ot | ottawa        -> $ROOT/.kube/config, context ottawa-k8s-operator.keiretsu.ts.net
  rb | robbinsdale   -> $ROOT/.kube/config, context robbinsdale-k8s-operator.keiretsu.ts.net
  sp | stpetersburg  -> ~/.kube/stpetersburg
examples:
  ${0##*/} ot -n media get pods
  ${0##*/} rb get ns
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }

context=""
case "$1" in
  ot|ottawa)       kubeconfig="$ROOT/.kube/config";  context="ottawa-k8s-operator.keiretsu.ts.net" ;;
  rb|robbinsdale)  kubeconfig="$ROOT/.kube/config";  context="robbinsdale-k8s-operator.keiretsu.ts.net" ;;
  sp|stpetersburg) kubeconfig="$HOME/.kube/stpetersburg" ;;
  -h|--help)       usage; exit 0 ;;
  *) echo "kc.sh: unknown cluster '$1' (valid: ot|ottawa rb|robbinsdale sp|stpetersburg)" >&2
     usage; exit 2 ;;
esac
shift

export KUBECONFIG="$kubeconfig"
if [ -n "$context" ]; then
  exec kubectl --context "$context" "$@"
fi
exec kubectl "$@"
