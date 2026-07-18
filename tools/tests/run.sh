#!/usr/bin/env bash
# tools/tests/run.sh — deterministic, offline self-tests for the tools/ helpers.
# No live cluster calls: kubectl/make are stubbed on PATH; orphans/where use
# temp fixtures and read-only repo lookups. Run: tools/tests/run.sh
set -u

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$ROOT/tools"
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
# assert LABEL CMD...  -> ok when CMD succeeds (grep reads stdin via <<< herestring)
assert() { local l="$1"; shift; if "$@"; then ok "$l"; else bad "$l"; fi; }
# refute LABEL CMD...  -> ok when CMD fails
refute() { local l="$1"; shift; if "$@"; then bad "$l"; else ok "$l"; fi; }
# exits  LABEL WANT CMD... -> ok when CMD's exit code equals WANT
exits()  { local l="$1" w="$2"; shift 2; "$@" >/dev/null 2>&1; local g=$?
           if [ "$g" = "$w" ]; then ok "$l (exit $g)"; else bad "$l (want $w got $g)"; fi; }
section() { printf '\n# %s\n' "$1"; }

# ---------------------------------------------------------------- kc.sh
section "kc.sh"
stub="$(mktemp -d)"
cat >"$stub/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "KUBECONFIG=$KUBECONFIG"
echo "ARGS=$*"
exit 7
EOF
chmod +x "$stub/kubectl"

exits  "no args -> usage exit 2"   2 "$T/kc.sh"
exits  "bad alias -> exit 2"       2 "$T/kc.sh" xx get ns
assert "bad alias lists valid aliases" grep -qi 'valid:' <<<"$("$T/kc.sh" xx 2>&1)"

out="$(PATH="$stub:$PATH" "$T/kc.sh" ot -n media get pods 2>&1)"; ec=$?
assert "ot -> repo kubeconfig"     grep -q "KUBECONFIG=$ROOT/.kube/config" <<<"$out"
assert "ot -> ottawa context"      grep -q -- '--context ottawa-k8s-operator.keiretsu.ts.net' <<<"$out"
assert "ot -> args passthrough"    grep -q -- 'ARGS=--context ottawa-k8s-operator.keiretsu.ts.net -n media get pods' <<<"$out"
assert "ot -> exit code passthrough (7)" test "$ec" = 7

rbout="$(PATH="$stub:$PATH" "$T/kc.sh" rb get ns 2>&1)"
assert "rb -> robbinsdale context" grep -q 'robbinsdale-k8s-operator.keiretsu.ts.net' <<<"$rbout"

spout="$(PATH="$stub:$PATH" "$T/kc.sh" sp get nodes 2>&1)"
assert "sp -> ~/.kube/stpetersburg" grep -q 'KUBECONFIG=.*/.kube/stpetersburg' <<<"$spout"
refute "sp -> no --context"         grep -q -- '--context' <<<"$spout"
rm -rf "$stub"

# ---------------------------------------------------------------- ktriage.sh
# Stubs kubectl (reached through kc.sh's exec) and dispatches on args. Every
# call is appended to $KUBECTL_CALLS so the read-only contract is checkable.
# Oversized fixtures (100 log lines, 15 events) prove the tail/cut bounds hold;
# the degraded_* fixtures fail one section after the pod-read gate to prove a
# later failure degrades (exit 4 + inline marker) instead of reading as empty.
section "ktriage.sh"
kstub="$(mktemp -d)"
cat >"$kstub/kubectl" <<'STUB'
#!/usr/bin/env bash
[ -n "${KUBECTL_CALLS:-}" ] && printf '%s\n' "$*" >>"$KUBECTL_CALLS"
args="$*"
case "$args" in
  *--previous*) awk 'BEGIN{for(i=1;i<=100;i++)print "PREVLOG-"i}'; exit 0 ;;
  *logs*)       awk 'BEGIN{for(i=1;i<=100;i++)print "LOGLINE-"i}'; exit 0 ;;
esac
case "${KT_FIXTURE:-crash}" in
  apifail)
    case "$args" in
      *custom-columns=PHASE*) echo 'Error from server (NotFound): pods "ghost" not found' >&2; exit 1 ;;
    esac
    exit 0 ;;
  ok)
    case "$args" in
      *"get events"*)          awk 'BEGIN{for(i=1;i<=2;i++)printf "2026-07-18T00:0%d:00Z Normal Started okEVT%d container started\n",i,i}'; exit 0 ;;
      *initContainerStatuses*) exit 0 ;;
      *containerStatuses*)     printf 'web\ttrue\t0\t\t2026-07-18T00:00:00Z\t\n'; exit 0 ;;
      *conditions*)            exit 0 ;;
      *custom-columns=PHASE*)  printf 'Running node-1 10.3.2.9 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
  degraded_events)
    # summary/states/conditions succeed; only the events query fails.
    case "$args" in
      *"get events"*)          echo 'Error from server: etcdserver: request timed out' >&2; exit 1 ;;
      *initContainerStatuses*) exit 0 ;;
      *containerStatuses*)     printf 'web\ttrue\t0\t\t2026-07-18T00:00:00Z\t\n'; exit 0 ;;
      *conditions*)            exit 0 ;;
      *custom-columns=PHASE*)  printf 'Running node-1 10.3.2.9 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
  degraded_state)
    # summary succeeds; the container-states query fails; events still succeed.
    case "$args" in
      *"get events"*)          awk 'BEGIN{for(i=1;i<=2;i++)printf "2026-07-18T00:0%d:00Z Normal Pulled EVT%d image pulled\n",i,i}'; exit 0 ;;
      *initContainerStatuses*) exit 0 ;;
      *containerStatuses*)     echo 'Error from server: unable to return a response' >&2; exit 1 ;;
      *conditions*)            exit 0 ;;
      *custom-columns=PHASE*)  printf 'Pending node-1 <none> 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
  multiline)
    # a multi-line terminated message must not spawn phantom container rows.
    case "$args" in
      *"get events"*)          exit 0 ;;
      *initContainerStatuses*) exit 0 ;;
      *containerStatuses*)     printf 'app\tfalse\t0\tError\t\tpanic: boom\ngoroutine 1 [running]:\nmain.main()\n'; exit 0 ;;
      *conditions*)            exit 0 ;;
      *custom-columns=PHASE*)  printf 'Running node-1 10.3.2.9 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
  *)
    case "$args" in
      *"get events"*)          awk 'BEGIN{for(i=1;i<=15;i++)printf "2026-07-18T00:%02d:00Z Warning BackOff EVT%02d back-off restarting failed container\n",i,i}'; exit 0 ;;
      *initContainerStatuses*) printf 'setup\ttrue\t0\tCompleted\t\t\n'; exit 0 ;;
      *containerStatuses*)     printf 'app\tfalse\t5\tCrashLoopBackOff\t\tback-off 5m0s restarting failed container=app\n'; exit 0 ;;
      *conditions*)            printf 'Ready\tContainersNotReady\tcontainers with unready status: [app]\nContainersReady\tContainersNotReady\tcontainers with unready status: [app]\n'; exit 0 ;;
      *custom-columns=PHASE*)  printf 'Running node-3 10.3.1.5 2026-07-18T00:00:00Z\n'; exit 0 ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$kstub/kubectl"
calls="$kstub/calls"

# --- bad usage (no cluster call needed) ---
exits  "no args -> usage exit 2"        2 "$T/ktriage.sh"
exits  "missing pod arg -> exit 2"      2 "$T/ktriage.sh" ot media
exits  "too many args -> exit 2"        2 "$T/ktriage.sh" ot media crashpod extra
assert "usage names ktriage"            grep -qi 'usage:.*ktriage' <<<"$("$T/ktriage.sh" 2>&1)"
exits  "bad cluster -> kc.sh exit 2"    2 "$T/ktriage.sh" xx media crashpod

# --- crashing / restarted container ---
: >"$calls"
cout="$(PATH="$kstub:$PATH" KT_FIXTURE=crash KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media crashpod 2>&1)"; cec=$?
assert "crash -> exit 0"                test "$cec" = 0
assert "crash -> summary phase"         grep -q 'PHASE=Running' <<<"$cout"
assert "crash -> container state"       grep -q 'app .*restarts=5 .*CrashLoopBackOff' <<<"$cout"
assert "crash -> init container state"  grep -q 'setup .*Completed' <<<"$cout"
assert "crash -> non-True condition"    grep -q 'Ready .*ContainersNotReady' <<<"$cout"
# events clamped to latest 10 despite 15 emitted
assert "crash -> latest event kept"     grep -q 'EVT15' <<<"$cout"
refute "crash -> 11th-from-end dropped" grep -q 'EVT05' <<<"$cout"
assert "crash -> exactly 10 events"     test "$(grep -c 'EVT[0-9]' <<<"$cout")" = 10
# current logs clamped to tail 20 despite 100 emitted
assert "crash -> last log line kept"    grep -q 'LOGLINE-100' <<<"$cout"
assert "crash -> 20th-from-end kept"    grep -q 'LOGLINE-81' <<<"$cout"
refute "crash -> 21st-from-end dropped" grep -q 'LOGLINE-80' <<<"$cout"
assert "crash -> exactly 20 cur logs"   test "$(grep -c 'LOGLINE-' <<<"$cout")" = 20
# previous logs shown for restarted container, also clamped
assert "crash -> previous logs shown"   grep -q 'PREVLOG-100' <<<"$cout"
assert "crash -> exactly 20 prev logs"  test "$(grep -c 'PREVLOG-' <<<"$cout")" = 20
assert "crash -> output <= 80 lines"    test "$(grep -c . <<<"$cout")" -le 80

# --- read-only contract (recorded verbs) ---
assert "calls include get pod"          grep -q 'get pod' "$calls"
assert "calls include logs"             grep -q 'logs' "$calls"
assert "calls use --request-timeout=10s" grep -q -- '--request-timeout=10s' "$calls"
assert "restarted -> uses --previous"   grep -q -- '--previous' "$calls"
refute "never dumps -o yaml"            grep -q -- '-o yaml' "$calls"
refute "never dumps -o json"            grep -qE -- '-o json($| )' "$calls"
refute "never touches secrets"          grep -qi 'secret' "$calls"
for v in apply delete exec patch create replace edit scale drain cordon rollout annotate label cp attach port-forward set; do
  refute "never runs verb: $v"          grep -qw "$v" "$calls"
done

# --- healthy / no-restart container ---
: >"$calls"
hout="$(PATH="$kstub:$PATH" KT_FIXTURE=ok KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media healthypod 2>&1)"; hec=$?
assert "healthy -> exit 0"              test "$hec" = 0
assert "healthy -> container shown"     grep -q 'web .*ready=true' <<<"$hout"
refute "healthy -> no crashloop"        grep -q 'CrashLoopBackOff' <<<"$hout"
refute "healthy -> no previous logs"    grep -q 'PREVLOG' <<<"$hout"
refute "healthy -> no --previous call"  grep -q -- '--previous' "$calls"
assert "healthy -> current logs clamped" test "$(grep -c 'LOGLINE-' <<<"$hout")" = 20
assert "healthy -> compact (<=40 ln)"   test "$(grep -c . <<<"$hout")" -le 40

# --- API failure -> nonzero, no misleading partial success ---
: >"$calls"
aout="$(PATH="$kstub:$PATH" KT_FIXTURE=apifail KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media ghost 2>&1)"; aec=$?
assert "api failure -> nonzero exit"    test "$aec" != 0
assert "api failure -> reports error"   grep -qiE 'error|not found|cannot read' <<<"$aout"
refute "api failure -> no log section"  grep -q 'LOGLINE' <<<"$aout"
refute "api failure -> no fake summary" grep -q 'PHASE=' <<<"$aout"

# --- later-section failure -> nonzero + inline marker, never mislabeled ---
# events query fails after the gate: must read "unavailable", not "(none)".
: >"$calls"
eout="$(PATH="$kstub:$PATH" KT_FIXTURE=degraded_events KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media evpod 2>&1)"; eec=$?
assert "events-fail -> exit 4 (partial)"      test "$eec" = 4
assert "events-fail -> summary still shown"   grep -q 'PHASE=Running' <<<"$eout"
assert "events-fail -> container still shown" grep -q 'web .*ready=true' <<<"$eout"
assert "events-fail -> unavailable marker"    grep -q 'events.*:' <<<"$eout"
assert "events-fail -> section marked"        grep -q '(unavailable' <<<"$eout"
refute "events-fail -> not mislabeled none"   grep -q '(none)' <<<"$eout"

# container-states query fails: marker + degrade, but later sections still run.
: >"$calls"
sfout="$(PATH="$kstub:$PATH" KT_FIXTURE=degraded_state KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media stpod 2>&1)"; sfec=$?
assert "state-fail -> exit 4 (partial)"       test "$sfec" = 4
assert "state-fail -> summary still shown"    grep -q 'PHASE=Pending' <<<"$sfout"
assert "state-fail -> states unavailable"     grep -q 'containers: (unavailable' <<<"$sfout"
assert "state-fail -> events still emitted"   grep -q 'EVT1' <<<"$sfout"

# --- multi-line container message must not spawn phantom rows / log fetches ---
: >"$calls"
mout="$(PATH="$kstub:$PATH" KT_FIXTURE=multiline KUBECTL_CALLS="$calls" "$T/ktriage.sh" ot media mlpod 2>&1)"; mec=$?
assert "multiline -> exit 0"                  test "$mec" = 0
assert "multiline -> real row kept"           grep -q 'app ready=false .*Error' <<<"$mout"
assert "multiline -> exactly one state row"   test "$(grep -c 'ready=' <<<"$mout")" = 1
refute "multiline -> no phantom row printed"  grep -q 'goroutine' <<<"$mout"
assert "multiline -> logs fetched for app"    grep -q -- '-c app' "$calls"
refute "multiline -> no phantom log fetch"    grep -q -- 'main.main' "$calls"
rm -rf "$kstub"

# ---------------------------------------------------------------- app.sh
section "app.sh"
list1="$("$T/app.sh" --list)"; list2="$("$T/app.sh" --list)"
assert "--list nonempty"           test -n "$list1"
assert "--list stable across runs" test "$list1" = "$list2"
assert "--list sorted+unique"      test "$list1" = "$(printf '%s\n' "$list1" | sort -u)"
assert "--list has immich row"     grep -q 'immich .*kubernetes/apps/base/immich/immich.* ottawa' <<<"$list1"
# shellcheck disable=SC2016  # $2 is an awk field, not a shell expansion
assert "--list rows well-formed"   awk 'NF<3 || $2 !~ /^kubernetes\/apps\/base\// {b=1} END{exit b+0}' <<<"$list1"
subout="$( (cd /tmp && "$T/app.sh" immich) 2>&1 )"
assert "substring immich (from /tmp)"  grep -q 'base manifests:' <<<"$subout"
exits  "substring no-match -> exit 1"  1 sh -c "cd /tmp && '$T/app.sh' zzz-nope-xyz"

# ---------------------------------------------------------------- refs.sh
section "refs.sh"
refs="$( (cd /tmp && "$T/refs.sh" immich) )"; ec=$?
assert "immich -> exit 0"          test "$ec" = 0
assert "immich -> nonempty"        test -n "$refs"
assert "output sorted+unique"      test "$refs" = "$(printf '%s\n' "$refs" | sort -u)"
allfiles=1; while IFS= read -r p; do [ -f "$ROOT/$p" ] || allfiles=0; done <<<"$refs"
assert "output lines are file paths" test "$allfiles" = 1
# PID-suffixed at runtime so the query literal can't self-match this tracked
# test file via refs.sh's content search (a static token would live here).
nomatch="zzz-refs-nomatch-$$"
exits  "no-match -> exit 1"         1 "$T/refs.sh" "$nomatch"
exits  "no args -> exit 2"          2 "$T/refs.sh"

# ---------------------------------------------------------------- orphans.sh
section "orphans.sh"
fx="$(mktemp -d)"
mkdir -p "$fx/clean" "$fx/dirty"
cat >"$fx/clean/kustomization.yaml" <<'EOF'
resources:
  - a.yaml
  - b.yaml
  - https://example.com/remote.yaml
EOF
: >"$fx/clean/a.yaml"; : >"$fx/clean/b.yaml"
exits  "clean fixture -> exit 0"    0 "$T/orphans.sh" "$fx/clean"
assert "clean fixture -> no output" test -z "$("$T/orphans.sh" "$fx/clean" 2>&1)"

mkdir -p "$fx/parent/child"
cat >"$fx/parent/kustomization.yaml" <<'EOF'
resources:
  - child/live.yaml
EOF
: >"$fx/parent/child/kustomization.yaml"
: >"$fx/parent/child/live.yaml"
exits  "direct parent reference -> not orphaned" 0 "$T/orphans.sh" "$fx/parent"

cat >"$fx/dirty/kustomization.yaml" <<'EOF'
resources:
  - present.yaml
  - gone.yaml
  - https://example.com/remote.yaml
patches:
  - path: patchme.yaml
  - patch: |-
      - op: add
        path: /metadata/labels/x
    target:
      kind: Deployment
EOF
: >"$fx/dirty/present.yaml"; : >"$fx/dirty/patchme.yaml"
: >"$fx/dirty/orphan.yaml"; : >"$fx/dirty/leftover.dec.yaml"
dout="$("$T/orphans.sh" "$fx/dirty" 2>&1)"; dec=$?
assert "dirty -> exit 1"                test "$dec" = 1
assert "flags missing resource"         grep -q 'MISSING.*gone.yaml' <<<"$dout"
assert "flags unlisted sibling"         grep -q 'UNLISTED.*orphan.yaml' <<<"$dout"
refute "ignores remote URL"             grep -q 'remote.yaml' <<<"$dout"
refute "ignores inline JSON6902 path"   grep -q '/metadata/labels' <<<"$dout"
refute "ignores generated .dec.yaml"    grep -q 'leftover.dec.yaml' <<<"$dout"
refute "listed patch not flagged"       grep -q 'patchme.yaml' <<<"$dout"
rm -rf "$fx"

# ---------------------------------------------------------------- where.sh
section "where.sh"
whereout="$( (cd /tmp && "$T/where.sh" 'resources' kubernetes/apps/base/immich/immich/app/kustomization.yaml) )"
assert "root-anchored repo-relative path (from /tmp)" grep -q 'resources' <<<"$whereout"
upperwhere="$( (cd /tmp && "$T/where.sh" 'RESOURCES' kubernetes/apps/base/immich/immich/app/kustomization.yaml) )"
assert "pattern matching is case-insensitive" test -n "$upperwhere"
exits  "missing file -> exit 1"     1 "$T/where.sh" foo /no/such/file.xyz

# ---------------------------------------------------------------- check.sh (stubbed make; no real render)
section "check.sh (stubbed make)"
mstub="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' >"$mstub/make"; chmod +x "$mstub/make"
sout="$(PATH="$mstub:$PATH" "$T/check.sh" 2>/dev/null)"; sec=$?
assert "success -> exit 0"              test "$sec" = 0
assert "success prints exactly 1 line"  test "$(printf '%s\n' "$sout" | grep -c .)" = 1
assert "success line format"            grep -q '^✓ render OK:' <<<"$sout"
printf '#!/usr/bin/env bash\necho "render Error: boom"; exit 1\n' >"$mstub/make"; chmod +x "$mstub/make"
fout="$(PATH="$mstub:$PATH" "$T/check.sh" 2>/dev/null)"; fec=$?
assert "failure -> exit 1"              test "$fec" = 1
assert "failure -> nothing on stdout"   test -z "$fout"
rm -rf "$mstub"

# ---------------------------------------------------------------- summary
printf '\n== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" = 0 ]
