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
#   sp | stpetersburg  repo .kube/config, context stpetersburg-k8s-operator.keiretsu.ts.net
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat >&2 <<EOF
usage: ${0##*/} <cluster> [kubectl args...]
clusters:
  ot | ottawa        -> $ROOT/.kube/config, context ottawa-k8s-operator.keiretsu.ts.net
  rb | robbinsdale   -> $ROOT/.kube/config, context robbinsdale-k8s-operator.keiretsu.ts.net
  sp | stpetersburg  -> \$ROOT/.kube/config, context stpetersburg-k8s-operator.keiretsu.ts.net
  eks|eks-use1|use1  -> AWS kubeconfig context for eks-use1
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
  sp|stpetersburg) kubeconfig="$ROOT/.kube/config"; context="stpetersburg-k8s-operator.keiretsu.ts.net" ;;
  eks|eks-use1|use1)
    # Prefer the AWS-updated kubeconfig; fall back to repo .kube/config if present.
    if [ -f "${HOME}/.kube/config" ]; then
      kubeconfig="${HOME}/.kube/config"
    else
      kubeconfig="$ROOT/.kube/config"
    fi
    # Resolve context by name fragment
    context="$(KUBECONFIG="$kubeconfig" kubectl config get-contexts -o name 2>/dev/null | grep -E 'eks-use1' | head -1 || true)"
    if [ -z "$context" ]; then
      echo "kc.sh: no kube context matching eks-use1; run: aws eks update-kubeconfig --name eks-use1 --region us-east-1" >&2
      exit 2
    fi
    ;;
  -h|--help)       usage; exit 0 ;;
  *) echo "kc.sh: unknown cluster '$1' (valid: ot|ottawa rb|robbinsdale sp|stpetersburg eks|eks-use1)" >&2
     usage; exit 2 ;;
esac
shift

export KUBECONFIG="$kubeconfig"
if [ -n "$context" ]; then
  exec kubectl --context "$context" "$@"
fi
exec kubectl "$@"
