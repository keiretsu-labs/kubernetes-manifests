# Phase 1: flate test+diff CI Implementation Plan

> **STATUS: COMPLETED** — All 11 tasks verified. Flate CI runs on every PR.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every PR gets offline-rendered validation (`flate test`) and a manifest diff comment (`flate diff`) for all three clusters, so later restructure phases have render/diff coverage.

**Architecture:** flate (home-operations' Go rewrite of flux-local) renders the entire Flux tree offline — Kustomizations, HelmReleases, postBuild substitution, SOPS values become placeholders. The repo currently has render failures in 6 classes — a dangling deprecated source plus 5 render-blocking classes (all verified with fixes below); they must be fixed first so CI starts green. Then a Makefile target for local runs and a GitHub workflow (test job + diff-comment job, matrix over the three clusters).

**Tech Stack:** flate ≥0.1.x (`brew install --cask home-operations/tap/flate`, CI via `home-operations/flate/action`), GitHub Actions, kustomize (for one-time vendoring).

**Verified facts (don't re-derive):**
- Flux entrypoint per cluster: `clusters/talos-<name>/flux/config/` (contains `cluster.yaml` with the GitRepository + `cluster` and `common-cluster` Kustomizations).
- Baseline: `flate test all --path clusters/talos-ottawa/flux/config` → 252 passed, 10 failed. Same failure classes on all three clusters.
- The `360-ai` GitRepository (bitbucket SSH source) is **deprecated** — nothing in the repo consumes it (`sourceRef: name: 360-ai` appears nowhere). Task 0 deletes it, which removes the only missing-secret failure, so NO flate flags are needed anywhere. (`tag:singh360` Tailscale tags on searxng/vllm/ai-gateway are unrelated live exposure tags — do NOT touch them.)
- flate has a URL-join bug with HelmRepository URLs lacking a trailing slash when the index has relative tgz URLs (drops the last path segment). Trailing slash fixes it — verified locally.
- valkey-helm upstream republished `valkey-0.9.4.tgz` without updating the index digest (index says `917cbf4e…`, actual asset is `a685b802…`). Not a flate bug; sourcing the chart from git at the release tag bypasses it.
- flate's kustomize sandbox cannot build remote *git directory* bases (`fs-security-constraint`). Remote *raw single-file* URLs work fine. Only the three git-dir bases need vendoring.

---

### Task 0: Remove the deprecated 360-ai source

The 360-ai project is deprecated (confirmed by Raj 2026-06-10). Its GitRepository is a dangling Flux source — no Kustomization or HelmRelease references it.

**Files:**
- Delete: `clusters/common/flux/repositories/git/360-ai.yaml`
- Delete: `clusters/common/flux/repositories/git/bitbucket-ssh-secret.sops.yaml`
- Modify: `clusters/common/flux/repositories/git/kustomization.yaml` (remove both entries)

- [ ] **Step 1: Confirm nothing consumes it**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
grep -rn "360-ai" clusters/ --include="*.yaml" | grep -v "repositories/git"
```

Expected: no output. (If anything appears, stop and triage — do not delete.)

- [ ] **Step 2: Delete the source and its secret**

```bash
git rm clusters/common/flux/repositories/git/360-ai.yaml clusters/common/flux/repositories/git/bitbucket-ssh-secret.sops.yaml
```

In `clusters/common/flux/repositories/git/kustomization.yaml`, remove the two lines:

```yaml
  - 360-ai.yaml
  - bitbucket-ssh-secret.sops.yaml
```

- [ ] **Step 3: Verify the missing-secret failure is gone**

```bash
flate test all --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | grep -c "360-ai"
```

Expected: `0` (and no `bitbucket-ssh-key` error in the failure list).

- [ ] **Step 4: Commit**

```bash
git add clusters/common/flux/repositories/git/kustomization.yaml
git commit -m "flux: remove deprecated 360-ai source and bitbucket ssh secret"
```

NOTE: Flux prunes the GitRepository and Secret from all three live clusters on reconcile — harmless since nothing consumes them.

---

### Task 1: Fix tailscale HelmRepository URLs (trailing slash)

**Files:**
- Modify: `clusters/common/flux/repositories/helm/tailscale.yaml:10` and `:19`

- [ ] **Step 1: Confirm the failure (red)**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
flate test hr -n tailscale --path clusters/talos-ottawa/flux/config --no-progress
```

Expected: FAIL — `download https://pkgs.tailscale.com/tailscale-operator-1.98.4-….tgz … 404` (note the missing `/helmcharts/` segment in the URL).

- [ ] **Step 2: Add trailing slashes**

In `clusters/common/flux/repositories/helm/tailscale.yaml`, change both `url:` lines:

```yaml
  url: https://pkgs.tailscale.com/helmcharts/
```

and

```yaml
  url: https://pkgs.tailscale.com/unstable/helmcharts/
```

(Flux treats both forms identically; only flate's URL join cares.)

- [ ] **Step 3: Verify (green)**

```bash
flate test hr -n tailscale --path clusters/talos-ottawa/flux/config --no-progress
```

Expected: `✓ 1 passed`

- [ ] **Step 4: Commit**

```bash
git add clusters/common/flux/repositories/helm/tailscale.yaml
git commit -m "flux: add trailing slash to tailscale helm repo urls for offline rendering"
```

---

### Task 2: Pin flux-operator and flux-instance chart versions

flate cannot resolve the semver range `">=0.1.0"` against OCI tags (passes it as a literal tag). Pinning is also what makes Renovate propose visible upgrade PRs.

**Files:**
- Modify: `clusters/common/apps/flux-system/flux-operator/app/helmrelease.yaml:11`
- Modify: `clusters/common/apps/flux-system/flux-instance/app/helmrelease.yaml:11`

- [ ] **Step 1: Confirm the failure (red)**

```bash
flate test hr -n flux-system --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | grep -E "flux-operator|flux-instance|passed|failed"
```

Expected: FAIL — `invalid reference: invalid tag ">=0.1.0"` for both.

- [ ] **Step 2: Find the current chart version**

Latest upstream release is v0.52.0 (checked 2026-06-10; charts are versioned with the operator). Confirm:

```bash
helm show chart oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator 2>/dev/null | grep '^version:'
helm show chart oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance 2>/dev/null | grep '^version:'
```

Use whatever version each prints below (referred to as `<VER>`).

- [ ] **Step 3: Pin both HelmReleases**

In both files, replace:

```yaml
      version: ">=0.1.0"
```

with:

```yaml
      version: "<VER>"
```

- [ ] **Step 4: Verify (green)**

```bash
flate test hr -n flux-system --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | tail -3
```

Expected: flux-operator and flux-instance both `✓` (other flux-system HRs were already passing).

- [ ] **Step 5: Commit**

```bash
git add clusters/common/apps/flux-system/flux-operator/app/helmrelease.yaml clusters/common/apps/flux-system/flux-instance/app/helmrelease.yaml
git commit -m "flux-system: pin flux-operator and flux-instance chart versions"
```

---

### Task 3: Source the valkey chart from git (upstream index digest is broken)

**Files:**
- Create: `clusters/common/flux/repositories/git/valkey-helm.yaml`
- Modify: `clusters/common/flux/repositories/git/kustomization.yaml`
- Modify: `clusters/talos-ottawa/apps/searxng/app/valkey.yaml:9-14`

- [ ] **Step 1: Confirm the failure (red)**

```bash
flate test hr -n searxng --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | tail -2
```

Expected: FAIL — `chart valkey@0.9.4 digest mismatch`.

- [ ] **Step 2: Create the GitRepository source**

Create `clusters/common/flux/repositories/git/valkey-helm.yaml`:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: valkey-helm
  namespace: flux-system
spec:
  interval: 1h
  url: https://github.com/valkey-io/valkey-helm
  ref:
    tag: valkey-0.9.4
```

- [ ] **Step 3: Register it**

In `clusters/common/flux/repositories/git/kustomization.yaml`, add to `resources:`:

```yaml
  - valkey-helm.yaml
```

- [ ] **Step 4: Point the HelmRelease at it**

In `clusters/talos-ottawa/apps/searxng/app/valkey.yaml`, replace the `chart.spec` block:

```yaml
  chart:
    spec:
      chart: ./valkey
      sourceRef:
        kind: GitRepository
        name: valkey-helm
        namespace: flux-system
```

(The chart lives at `valkey/` in that repo — verified. Remove the `version:` line; the git tag pins it.)

- [ ] **Step 5: Verify (green)**

```bash
flate test hr -n searxng --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | tail -2
```

Expected: `✓ … passed`, no digest mismatch.

- [ ] **Step 6: Commit**

```bash
git add clusters/common/flux/repositories/git/valkey-helm.yaml clusters/common/flux/repositories/git/kustomization.yaml clusters/talos-ottawa/apps/searxng/app/valkey.yaml
git commit -m "searxng: source valkey chart from git tag (upstream index digest mismatch)"
```

---

### Task 4: Fix cert-manager priorityClassName values placement

Real bug flate caught: chart v1.20.2's values schema rejects top-level `priorityClassName`. The supported key is `global.priorityClassName`.

**Files:**
- Modify: `clusters/common/apps/cert-manager/app/helmrelease.yaml:23-29`

- [ ] **Step 1: Confirm the failure (red)**

```bash
flate test hr -n cert-manager --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | tail -3
```

Expected: FAIL — `additional properties 'priorityClassName' not allowed`.

- [ ] **Step 2: Move the key under global**

In `clusters/common/apps/cert-manager/app/helmrelease.yaml`, change the start of the `values:` block from:

```yaml
  values:
    prometheus:
      enabled: true
      servicemonitor:
        enabled: true
    installCRDs: true
    priorityClassName: "infra-critical"
```

to:

```yaml
  values:
    global:
      priorityClassName: "infra-critical"
    prometheus:
      enabled: true
      servicemonitor:
        enabled: true
    installCRDs: true
```

- [ ] **Step 3: Verify (green)**

```bash
flate test hr -n cert-manager --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | tail -2
```

Expected: PASS. Optionally confirm the rendered Deployment actually carries the priorityClassName:

```bash
flate build hr --path clusters/talos-ottawa/flux/config -n cert-manager cert-manager 2>/dev/null | grep -m2 "priorityClassName"
```

Expected: `priorityClassName: infra-critical`

- [ ] **Step 4: Commit**

```bash
git add clusters/common/apps/cert-manager/app/helmrelease.yaml
git commit -m "cert-manager: move priorityClassName under global (chart schema violation)"
```

---

### Task 5: Vendor the descheduler cronjob base (3 cilium app dirs)

flate's kustomize sandbox rejects remote git-directory bases. Vendor the rendered upstream YAML; the surrounding kustomization's patches still apply. Bonus: `release-1.32` is a mutable branch, so vendoring also pins it.

**Files:**
- Create: `clusters/talos-ottawa/apps/cilium/app/descheduler-cronjob.yaml`
- Create: `clusters/talos-robbinsdale/apps/cilium/app/descheduler-cronjob.yaml`
- Create: `clusters/talos-stpetersburg/apps/cilium/app/descheduler-cronjob.yaml`
- Modify: `clusters/talos-{ottawa,robbinsdale,stpetersburg}/apps/cilium/app/kustomization.yaml` (the `github.com/kubernetes-sigs/descheduler/...` line, line 10 in ottawa's)

- [ ] **Step 1: Confirm the failure (red)**

```bash
flate test ks --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | grep -m1 cilium
```

Expected: FAIL — `fs-security-constraint` on the descheduler base.

- [ ] **Step 2: Render the upstream base once**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
UPSTREAM_SHA=$(git ls-remote https://github.com/kubernetes-sigs/descheduler release-1.32 | cut -f1)
{
  echo "# Vendored from github.com/kubernetes-sigs/descheduler/kubernetes/cronjob?ref=release-1.32"
  echo "# upstream commit: ${UPSTREAM_SHA} — re-render with: kustomize build 'github.com/kubernetes-sigs/descheduler/kubernetes/cronjob?ref=release-1.32'"
  kustomize build "github.com/kubernetes-sigs/descheduler/kubernetes/cronjob?ref=release-1.32"
} > clusters/talos-ottawa/apps/cilium/app/descheduler-cronjob.yaml
cp clusters/talos-ottawa/apps/cilium/app/descheduler-cronjob.yaml clusters/talos-robbinsdale/apps/cilium/app/descheduler-cronjob.yaml
cp clusters/talos-ottawa/apps/cilium/app/descheduler-cronjob.yaml clusters/talos-stpetersburg/apps/cilium/app/descheduler-cronjob.yaml
```

- [ ] **Step 3: Swap the resource reference in all three kustomizations**

In each `clusters/talos-<cluster>/apps/cilium/app/kustomization.yaml`, replace the line:

```yaml
  - github.com/kubernetes-sigs/descheduler/kubernetes/cronjob?ref=release-1.32
```

with:

```yaml
  - descheduler-cronjob.yaml
```

- [ ] **Step 4: Check for `$` characters in the vendored file**

Flux postBuild envsubst mangles bare `$` (see repo CLAUDE.md). Run:

```bash
grep -n '\$' clusters/talos-ottawa/apps/cilium/app/descheduler-cronjob.yaml || echo CLEAN
```

If any `$` appears inside script/args content, escape it as `$$`. (Expected: CLEAN — the descheduler cronjob manifests carry no shell vars.)

- [ ] **Step 5: Verify (green)**

```bash
flate test ks --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | grep -E "cilium|passed|failed" | tail -4
```

Expected: cilium and cilium-config pass (local-path-storage may still fail — that's Task 6).

- [ ] **Step 6: Commit**

```bash
git add clusters/talos-*/apps/cilium/app/
git commit -m "cilium: vendor descheduler cronjob manifests (pin release-1.32, enable offline rendering)"
```

---

### Task 6: Vendor the local-path-provisioner base (3 dirs)

**Files:**
- Create: `clusters/talos-{ottawa,robbinsdale,stpetersburg}/apps/local-path-storage/app/local-path-provisioner.yaml`
- Modify: `clusters/talos-{ottawa,robbinsdale,stpetersburg}/apps/local-path-storage/app/kustomization.yaml` (the `github.com/rancher/local-path-provisioner/deploy?ref=v0.0.36` line)

- [ ] **Step 1: Render the upstream base once**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
{
  echo "# Vendored from github.com/rancher/local-path-provisioner/deploy?ref=v0.0.36"
  echo "# re-render with: kustomize build 'github.com/rancher/local-path-provisioner/deploy?ref=v0.0.36'"
  kustomize build "github.com/rancher/local-path-provisioner/deploy?ref=v0.0.36"
} > clusters/talos-ottawa/apps/local-path-storage/app/local-path-provisioner.yaml
cp clusters/talos-ottawa/apps/local-path-storage/app/local-path-provisioner.yaml clusters/talos-robbinsdale/apps/local-path-storage/app/
cp clusters/talos-ottawa/apps/local-path-storage/app/local-path-provisioner.yaml clusters/talos-stpetersburg/apps/local-path-storage/app/
```

- [ ] **Step 2: Swap the resource reference in all three kustomizations**

Replace `- github.com/rancher/local-path-provisioner/deploy?ref=v0.0.36` with `- local-path-provisioner.yaml` in each of the three `kustomization.yaml` files.

- [ ] **Step 3: Escape `$` in the helper-pod setup scripts**

local-path-provisioner's ConfigMap embeds shell scripts that use `$VAR` syntax — these WILL be mangled by Flux envsubst. Check and escape:

```bash
grep -n '\$' clusters/talos-ottawa/apps/local-path-storage/app/local-path-provisioner.yaml
```

For every `$` that is part of shell syntax (e.g. `$VOL_DIR`, `$(dirname $0)`), replace `$` with `$$` in all three copies. IMPORTANT: this matches what Flux's drone/envsubst expects for literal dollars; the deployed output is then byte-identical to today's remote-base render. Compare to be sure:

```bash
flate build ks --path clusters/talos-ottawa/flux/config local-path-storage 2>/dev/null | grep -A5 "setup"
```

Expected: script content shows single `$` (flate emulates the substitution pass).

- [ ] **Step 4: Verify (green)**

```bash
flate test ks --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | grep -E "local-path|passed|failed" | tail -3
```

Expected: local-path-storage passes.

- [ ] **Step 5: Commit**

```bash
git add clusters/talos-*/apps/local-path-storage/app/
git commit -m "local-path-storage: vendor provisioner manifests v0.0.36 for offline rendering"
```

---

### Task 7: Vendor the intel NFD base (common)

**Files:**
- Create: `clusters/common/apps/node-feature-discovery/install/intel-nfd.yaml`
- Modify: `clusters/common/apps/node-feature-discovery/install/kustomization.yaml:5`

- [ ] **Step 1: Render and pin (currently `ref=main` — mutable!)**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
UPSTREAM_SHA=$(git ls-remote https://github.com/intel/intel-device-plugins-for-kubernetes main | cut -f1)
{
  echo "# Vendored from https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=main"
  echo "# upstream commit at vendor time: ${UPSTREAM_SHA}"
  kustomize build "https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=main"
} > clusters/common/apps/node-feature-discovery/install/intel-nfd.yaml
```

- [ ] **Step 2: Swap the reference**

In `clusters/common/apps/node-feature-discovery/install/kustomization.yaml`, replace:

```yaml
  - https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/nfd?ref=main
```

with:

```yaml
  - intel-nfd.yaml
```

- [ ] **Step 3: Check `$` characters**

```bash
grep -n '\$' clusters/common/apps/node-feature-discovery/install/intel-nfd.yaml || echo CLEAN
```

Escape any shell-script `$` as `$$` (same rule as Task 6).

- [ ] **Step 4: Verify (green)**

```bash
flate test ks --path clusters/talos-ottawa/flux/config --no-progress 2>&1 | grep -E "nfd|passed|failed" | tail -3
```

Expected: nfd-install passes.

- [ ] **Step 5: Commit**

```bash
git add clusters/common/apps/node-feature-discovery/install/
git commit -m "node-feature-discovery: vendor intel nfd manifests (pin upstream, enable offline rendering)"
```

---

### Task 8: Full three-cluster green verification

- [ ] **Step 1: Run all three clusters**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
for c in talos-ottawa talos-robbinsdale talos-stpetersburg; do
  echo "=== $c ==="
  flate test all --path clusters/$c/flux/config --no-progress 2>&1 | tail -1
done
```

Expected: each cluster ends with `✓ <N> passed` and **0 failed, 0 skipped**.

- [ ] **Step 2: If anything still fails**

Each remaining failure is either a new instance of a class above (apply the same fix) or genuinely new — stop and triage before proceeding; do NOT silence it with flags.

- [ ] **Step 3: Sanity-check the diff command**

```bash
flate diff all --path clusters/talos-ottawa/flux/config --base HEAD -o github 2>&1 | tail -3
```

Expected: empty diff / "no changes" output, exit 0.

---

### Task 9: Makefile flate targets

The existing `validate-kustomize` target only covers robbinsdale and depends on an undefined `install-deps`. Replace it.

**Files:**
- Modify: `Makefile` (full replacement below)

- [ ] **Step 1: Replace the Makefile contents**

```makefile
.PHONY: help test test-ottawa test-robbinsdale test-stpetersburg diff

CLUSTERS := talos-ottawa talos-robbinsdale talos-stpetersburg
FLATE_FLAGS := --no-progress

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

test: ## Render-test all clusters with flate
	@for c in $(CLUSTERS); do \
		echo "=== $$c ==="; \
		flate test all --path clusters/$$c/flux/config $(FLATE_FLAGS) || exit 1; \
	done

test-%: ## Render-test one cluster, e.g. make test-talos-ottawa
	flate test all --path clusters/$* /flux/config $(FLATE_FLAGS)

diff: ## Show rendered diff vs origin/main for all clusters
	@for c in $(CLUSTERS); do \
		echo "=== $$c ==="; \
		flate diff all --path clusters/$$c/flux/config --base origin/main $(FLATE_FLAGS); \
	done
```

NOTE: remove the space in `clusters/$* /flux/config` → `clusters/$*/flux/config` (markdown escaping artifact; the real file must not contain that space).

- [ ] **Step 2: Verify**

```bash
make help && make test-talos-ottawa 2>&1 | tail -1
```

Expected: help lists the targets; the test run ends `0 failed`.

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "make: replace validate-kustomize with flate test/diff targets"
```

---

### Task 10: GitHub workflow — flate test + diff on PRs

**Files:**
- Create: `.github/workflows/flate.yaml`

- [ ] **Step 1: Write the workflow**

```yaml
name: flate

on:
  pull_request:
    branches: [main]
    paths:
      - "clusters/**"
  workflow_dispatch:

concurrency:
  group: flate-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        cluster: [talos-ottawa, talos-robbinsdale, talos-stpetersburg]
    steps:
      - uses: actions/checkout@v6
      - uses: home-operations/flate/action@main
        with:
          cache: true
      - name: flate test
        run: >-
          flate test all
          --path clusters/${{ matrix.cluster }}/flux/config
          --no-progress

  diff:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
      pull-requests: write
    strategy:
      fail-fast: false
      matrix:
        cluster: [talos-ottawa, talos-robbinsdale, talos-stpetersburg]
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - uses: home-operations/flate/action@main
        with:
          cache: true
      - name: flate diff
        id: diff
        run: |
          flate diff all \
            --path clusters/${{ matrix.cluster }}/flux/config \
            --base origin/main \
            --no-progress \
            -o github > diff.md || true
          if [ ! -s diff.md ]; then
            echo "No rendered changes for ${{ matrix.cluster }}." > diff.md
          fi
          # sticky-comment body limit
          head -c 60000 diff.md > comment.md
          if [ "$(wc -c < diff.md)" -gt 60000 ]; then
            echo "" >> comment.md
            echo "_…truncated; run \`make diff\` locally for the full diff._" >> comment.md
          fi
          cat comment.md >> "$GITHUB_STEP_SUMMARY"
      - uses: marocchino/sticky-pull-request-comment@v2
        with:
          header: flate-diff-${{ matrix.cluster }}
          path: comment.md
```

- [ ] **Step 2: Validate workflow syntax locally**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/flate.yaml'))" && echo OK
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/flate.yaml
git commit -m "ci: flate render test + manifest diff comments on prs"
```

- [ ] **Step 4: Open a smoke-test PR**

Push a branch with a trivial rendered change (e.g. bump a HelmRelease `interval`) and confirm: test job green ×3, diff job posts three sticky comments each showing just that change. Then close the PR without merging (or merge if the change is harmless).

```bash
git checkout -b ci/flate-smoke
# edit clusters/talos-ottawa/apps/searxng/app/valkey.yaml: interval: 30m -> 35m
git commit -am "searxng: smoke-test flate ci (interval bump)" && git push -u origin ci/flate-smoke
gh pr create --fill
```

Expected: all 6 jobs pass; ottawa's diff comment shows the interval change; the other two say "No rendered changes."

---

### Task 11: Docs

**Files:**
- Modify: `README.md` (add a "validating changes" section)

- [ ] **Step 1: Add to README.md** (after the existing intro/structure section):

```markdown
## validating changes

Every PR is rendered offline with [flate](https://github.com/home-operations/flate):

- `make test` — render-test all three clusters (what CI runs)
- `make test-talos-ottawa` — one cluster
- `make diff` — rendered manifest diff vs origin/main (CI comments this on your PR)

Install: `brew install --cask home-operations/tap/flate`

Gotchas the CI will catch for you: helm values schema violations, broken kustomizations,
unresolvable chart versions. Remote *git-directory* kustomize bases don't render offline —
vendor the YAML instead (see `clusters/*/apps/cilium/app/descheduler-cronjob.yaml` for the
pattern). SOPS secret values render as placeholders.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document flate validation workflow"
```

---

## Self-review notes

- Spec coverage: phase 1 scope is "flate test+diff CI against the current tree" — Tasks 1-8 make the tree renderable (prerequisite), 9-10 are the CI, 11 docs. Later phases (gateway listeners, OIDC, tree migration) intentionally not here.
- The failure classes were each reproduced and their fixes verified locally on 2026-06-10 (trailing slash tested directly; valkey digest mismatch confirmed as upstream index inconsistency by hashing the release asset; 360-ai confirmed dangling and deprecated by Raj).
- Live-cluster risk: Tasks 1-2 are render-only changes (Flux resolves identically). Task 3 changes the chart *source* (same chart version → same rendered output; the diff job on its own PR proves it). Task 4 changes where priorityClassName lands — the rendered output check in the task confirms it actually applies now (it was being rejected... by schema validation at render time; live helm may have silently dropped it, so this may *add* priorityClassName to live pods — that's the intended fix). Tasks 5-7 must be verified byte-identical via the PR diff comment from Task 10's smoke test or `flate diff` locally before merge.
