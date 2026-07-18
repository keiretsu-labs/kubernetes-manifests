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
exits  "no-match -> exit 1"         1 "$T/refs.sh" zzz-nonexistent-xyz
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
