#!/usr/bin/env bash
# Offline integration tests: the App API and kubectl are both faked.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/kgh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
method=$1 path=$2
echo "$method $path" >>"$CALLS"
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
merge=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
case "$path" in
  */pulls/7/files*)
    if [[ ${CASE:-} == unsafe ]]; then name=kubernetes/apps/base/home/x/helmrelease.yaml; else name=tools/merge-one.sh; fi
    printf '[{"filename":"%s","status":"modified"}]\n' "$name" ;;
  */pulls/7/merge)
    touch "$MERGED_MARKER"
    printf '{"merged":true,"sha":"%s"}\n' "$merge" ;;
  */pulls/7)
    login=keiretsu-kman-bot; title='Add tool'; state=clean
    [[ ${CASE:-} == renovate ]] && login=renovate-bot
    [[ ${CASE:-} == held ]] && title='HELD-FOR-ROLLOUT: add tool'
    printf '{"state":"open","draft":false,"base":{"ref":"main","sha":"cccccccccccccccccccccccccccccccccccccccc"},"head":{"sha":"%s"},"mergeable":true,"mergeable_state":"%s","title":"%s","labels":[],"user":{"login":"%s"},"changed_files":1}\n' "$head" "$state" "$title" "$login" ;;
  */check-runs*)
    conclusion=success; [[ ${CASE:-} == red ]] && conclusion=failure
    printf '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"%s"}]}\n' "$conclusion" ;;
  */status)
    echo '{"state":"pending","statuses":[]}' ;;
  *) echo '{"message":"unexpected API route"}' ;;
esac
STUB
cat >"$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$KUBE_CALLS"
case " $* " in
  *' get '* )
    if [[ ${CASE:-} == baseline_fail ]]; then exit 1; fi
    if [[ ${CASE:-} == new_unhealthy && -f $MERGED_MARKER ]]; then
      echo '{"items":[{"kind":"Kustomization","metadata":{"namespace":"flux-system","name":"broken"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}'
    else
      echo '{"items":[{"kind":"Kustomization","metadata":{"namespace":"flux-system","name":"old"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}'
    fi ;;
  *' wait '* )
    [[ ${CASE:-} != wait_fail ]] ;;
  *) exit 3 ;;
esac
STUB
chmod +x "$T/kgh" "$T/bin/kubectl"
export PATH="$T/bin:$PATH" MERGE_ONE_TEST_KGH="$T/kgh" CALLS="$T/calls" KUBE_CALLS="$T/kubecalls" MERGED_MARKER="$T/merged"
pass=0
run_case() {
  local scenario=$1 expected=$2
  export CASE=$scenario
  : >"$CALLS"; : >"$KUBE_CALLS"; rm -f "$MERGED_MARKER" "$T/baseline"
  set +e
  "$ROOT/tools/merge-one.sh" --pr 7 --baseline "$T/baseline" --timeout 30 >"$T/output" 2>&1
  got=$?
  set -e
  if [[ $got != "$expected" ]]; then cat "$T/output"; echo "FAIL $scenario: exit $got expected $expected"; exit 1; fi
  if [[ $scenario == success || $scenario == new_unhealthy || $scenario == wait_fail ]]; then
    [[ -f $T/baseline ]] || { echo "FAIL $scenario: no baseline"; exit 1; }
  else
    [[ ! -f $T/baseline ]] || { echo "FAIL $scenario: unexpected baseline"; exit 1; }
  fi
  if [[ $scenario == success || $scenario == new_unhealthy || $scenario == wait_fail ]]; then
    grep -q 'PUT .*/pulls/7/merge' "$CALLS" || { echo "FAIL $scenario: no merge"; exit 1; }
  else
    ! grep -q 'PUT .*/pulls/7/merge' "$CALLS" || { echo "FAIL $scenario: unsafe merge"; exit 1; }
  fi
  if [[ $scenario == success ]]; then
    ! grep -E ' (apply|patch|delete|create|edit|replace) ' "$KUBE_CALLS" || exit 1
    grep -q 'passed Flux health gate' "$T/output" || exit 1
  fi
  if [[ $scenario == new_unhealthy ]]; then grep -q 'newly not-ready Flux resources' "$T/output" || exit 1; fi
  pass=$((pass+1))
}
run_case success 0
run_case renovate 1
run_case held 1
run_case unsafe 1
run_case red 1
run_case baseline_fail 1
run_case new_unhealthy 1
run_case wait_fail 1
set +e
"$ROOT/tools/merge-one.sh" --pr 7 >"$T/output" 2>&1
missing=$?
set -e
[[ $missing == 2 ]] || { echo "FAIL missing baseline: exit $missing"; exit 1; }
pass=$((pass+1))
echo "merge-one.sh: $pass offline cases passed"
