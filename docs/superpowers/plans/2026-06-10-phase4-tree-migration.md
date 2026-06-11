# Phase 4: Tree Migration — Foundation, Recipe, Pilot, Wave 1

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `kubernetes/` base+pointer tree, prove a zero-churn app-move recipe on a pilot, migrate the first wave, and document the recipe so every later wave is a mechanical repeat.

**Architecture:** The current tree ALREADY gives every app its own Flux Kustomization CR (e.g. `kromgo`, applied by the `common-apps` parent) that owns the app's workload objects. Migration therefore never touches workload ownership: the same-named Kustomization CR moves to a new parent (`kubernetes-apps`) with a new `spec.path`, rendering identical content from the new location. Flux's garbage collection skips objects whose ownership labels have been taken over by another Kustomization, so the move is a two-PR adoption dance with zero recreation: **PR-A adds the app to the new tree (new parent adopts the CR) → verify live → PR-B deletes it from the old tree (old parent skips the now-foreign object).**

**Tech Stack:** Flux kustomize-controller SSA/GC semantics, Kustomize, flate CI, the three live clusters.

---

## Verified facts

- Per-app Kustomization CRs exist today: `clusters/common/apps/<app>/ks.yaml` (e.g. `headlamp-install` with `targetNamespace`, `commonMetadata`, `path: ./clusters/common/apps/headlamp/install`). The `common-apps` parent (`clusters/common/flux/apps.yaml`) patches sops decryption + the full `substituteFrom` stack into every child via a labelSelector patch (`substitution.flux.home.arpa/disabled notin (true)`), so child ks.yaml files that carry their own substituteFrom blocks are belt-and-braces duplicates.
- GitRepository sync scope is a whitelist per cluster (`clusters/talos-<c>/flux/config/cluster.yaml` spec.ignore). The new `/kubernetes` directory MUST be whitelisted on all three or nothing reconciles. Robbinsdale's list additionally contains `!/swarm` and `!/laptop` — preserve them.
- flate renders whatever `clusters/<c>/flux/config/cluster.yaml` defines, so adding the new entrypoint there automatically puts the new tree under CI render coverage.
- `StrictPostBuildSubstitutions` is a kustomize-controller **feature gate** (controller flag), not a per-Kustomization field. Enabling it now would affect the old tree, which may depend on undefined-var→empty-string behavior. **Deferred to phase 5** (spec note updated in Task 5).
- The oidc-protect component stays at `clusters/common/components/` until its consumers migrate (hubble references it by relative path); it moves in the wave that moves hubble-ui.
- Pilot: `kromgo` (stateless badge exporter, common app, self-contained dir). Wave 1: `unpoller`, `blackbox-exporter` (both small, stateless, common).
- Old-tree registration: `clusters/common/apps/kustomization.yaml` lists every app dir; PR-B removals must also drop the entry there.
- Base-app content is copied **verbatim** in this phase — variables and all. Literal-hostname cleanup happens in later waves as separate commits, never mixed into a move (byte-identical rendering is what makes moves provably safe).

---

### Task 1: Skeleton + new Flux entrypoints (foundation PR)

**Files:**
- Create: `kubernetes/apps/base/.gitkeep` (placeholder; removed when first app lands)
- Create: `kubernetes/apps/{ottawa,robbinsdale,stpetersburg}/kustomization.yaml`
- Create: `kubernetes/components/.gitkeep`
- Modify: `clusters/talos-{ottawa,robbinsdale,stpetersburg}/flux/config/cluster.yaml` (whitelist + new Kustomization)

- [ ] **Step 1: Per-location root kustomizations (empty but valid)**

Each `kubernetes/apps/<loc>/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
```

- [ ] **Step 2: Wire each cluster's entrypoint**

In each `clusters/talos-<c>/flux/config/cluster.yaml`:

(a) add `!/kubernetes` to the GitRepository `spec.ignore` whitelist (after the existing `!/clusters/...` lines, preserving robbinsdale's extra entries);

(b) append a third Kustomization document (ottawa shown; robbinsdale/stpetersburg substitute their location in `path`):

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kubernetes-apps
  namespace: flux-system
spec:
  interval: 30m
  path: ./kubernetes/apps/ottawa
  prune: true
  wait: false
  sourceRef:
    kind: GitRepository
    name: kubernetes-manifests
  decryption:
    provider: sops
    secretRef:
      name: sops-gpg
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: common-settings
      - kind: Secret
        name: common-secrets
      - kind: ConfigMap
        name: cluster-settings
      - kind: Secret
        name: cluster-secrets
      - kind: ConfigMap
        name: cluster-user-settings
        optional: true
      - kind: Secret
        name: cluster-user-secrets
        optional: true
  patches:
    - patch: |-
        apiVersion: kustomize.toolkit.fluxcd.io/v1
        kind: Kustomization
        metadata:
          name: not-used
        spec:
          wait: false
          decryption:
            provider: sops
            secretRef:
              name: sops-gpg
          postBuild:
            substituteFrom:
              - kind: ConfigMap
                name: common-settings
              - kind: Secret
                name: common-secrets
              - kind: ConfigMap
                name: cluster-settings
              - kind: Secret
                name: cluster-secrets
              - kind: ConfigMap
                name: cluster-user-settings
                optional: true
              - kind: Secret
                name: cluster-user-secrets
                optional: true
      target:
        group: kustomize.toolkit.fluxcd.io
        kind: Kustomization
        labelSelector: substitution.flux.home.arpa/disabled notin (true)
```

(The patch mirrors `common-apps` so pointer ks.yaml files can eventually be thin; verbatim-copied ks.yaml files with their own substituteFrom blocks also keep working.)

- [ ] **Step 3: Gate + ship**

`make test` ×3 green (flate must render the new empty entrypoint without error). Branch `migrate/phase4-foundation`, PR titled `flux: kubernetes/ tree skeleton and per-cluster entrypoints`, expect an empty-ish rendered diff (3 new Kustomization CRs + GitRepository ignore change only). Merge when green; reconcile each cluster and confirm `flux get ks kubernetes-apps -n flux-system` is Ready on all three.

---

### Task 2: Pilot PR-A — kromgo enters the new tree (adoption)

**Files (PR-A touches ONLY the new tree):**
- Create: `kubernetes/apps/base/kromgo/kromgo/app/...` — verbatim copy of `clusters/common/apps/kromgo/app/`
- Create: `kubernetes/apps/{ottawa,robbinsdale,stpetersburg}/kromgo/kustomization.yaml` + `.../kromgo/kromgo.yaml` + namespace file as needed
- Modify: `kubernetes/apps/<loc>/kustomization.yaml` (add `- ./kromgo`)

- [ ] **Step 1: Read the old app first.** `clusters/common/apps/kromgo/{ks.yaml,kustomization.yaml}` and `app/`. Note the Kustomization CR's exact `metadata.name`, `targetNamespace`, `dependsOn`, and whether the old `kustomization.yaml` carries a `namespace.yaml` (if kromgo deploys into its own namespace, the Namespace object moves too, keeping its `kustomize.toolkit.fluxcd.io/prune: disabled` label).

- [ ] **Step 2: Lay out the new shape.**

- `kubernetes/apps/base/<ns>/kromgo/` ← verbatim copy of the old `app/` directory (use the app's target namespace as `<ns>`).
- Per location: `kubernetes/apps/<loc>/<ns>/kromgo.yaml` ← verbatim copy of the old `ks.yaml` with EXACTLY ONE field changed: `spec.path: ./kubernetes/apps/base/<ns>/kromgo`. The CR name must stay identical — that is the adoption key.
- Per location: `kubernetes/apps/<loc>/<ns>/kustomization.yaml` listing the namespace.yaml (copied) + `kromgo.yaml`; register `- ./<ns>` in the location root kustomization.
- Remove `kubernetes/apps/base/.gitkeep`.

- [ ] **Step 3: Render proof — byte-identical app.**

```bash
make test 2>&1 | grep -E "===|passed|failed"
flate build ks --path clusters/talos-ottawa/flux/config kromgo 2>/dev/null > /tmp/kromgo-new.yaml
git stash && flate build ks --path clusters/talos-ottawa/flux/config kromgo 2>/dev/null > /tmp/kromgo-old.yaml; git stash pop
diff /tmp/kromgo-old.yaml /tmp/kromgo-new.yaml
```

Expected: empty diff (the kromgo Kustomization renders identical workloads from the new path). The cluster-level flate diff should show ONLY the kromgo Kustomization CR's `spec.path` change + its parent-label move. NOTE: during PR-A both trees define the same CR — flate may warn about a duplicate object across two Kustomizations; confirm rendering still succeeds (if flate hard-errors on the duplicate, record the exact error and proceed only if it's a warning — a hard error means the recipe needs the old ks.yaml deleted in the same PR with `prune: false` set first; STOP and report BLOCKED in that case).

- [ ] **Step 4: Ship PR-A and verify live adoption.**

Branch `migrate/pilot-kromgo-a`, PR `migrate: kromgo into the kubernetes tree (adopt)`. Merge when CI green and diff matches. Then on each cluster:

```bash
flux --context <ctx> reconcile source git kubernetes-manifests -n flux-system
flux --context <ctx> reconcile kustomization kubernetes-apps -n flux-system --with-source=false
kubectl --context <ctx> get kustomization kromgo -n flux-system -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}'   # expect: kubernetes-apps
kubectl --context <ctx> get kustomization kromgo -n flux-system -o jsonpath='{.spec.path}'                                            # expect: ./kubernetes/apps/base/<ns>/kromgo
kubectl --context <ctx> get pods -n <ns> -o jsonpath='{range .items[*]}{.metadata.name} {.status.startTime}{"\n"}{end}'              # pod start times UNCHANGED
```

The label flip + unchanged pod start times = adoption succeeded with zero workload churn. If the old `common-apps` parent re-flips the label on its next reconcile (apply fight), record it — that means both parents still apply the CR (expected during the A→B window; ownership fights on the CR are tolerable for hours, NOT weeks — proceed promptly to PR-B).

---

### Task 3: Pilot PR-B — kromgo leaves the old tree (prune safety)

**Files:**
- Delete: `clusters/common/apps/kromgo/` (entire directory)
- Modify: `clusters/common/apps/kustomization.yaml` (remove the kromgo entry)

- [ ] **Step 1: Ship PR-B.** Branch `migrate/pilot-kromgo-b`, PR `migrate: kromgo out of the old tree (release)`. The rendered cluster diff should show NO change to the kromgo Kustomization CR or workloads IF the new parent's version is what's live (labels already flipped) — flate diffs against main render both trees, so expect flate to show the old-tree copy disappearing while the object survives via the new tree. Merge when green.

- [ ] **Step 2: The critical live check — nothing gets pruned.**

```bash
flux --context <ctx> reconcile kustomization common-apps -n flux-system --with-source=false
kubectl --context <ctx> get kustomization kromgo -n flux-system && echo "CR survived"
kubectl --context <ctx> get pods -n <ns> --no-headers | head -3   # still running, same start times
flux --context <ctx> get ks kromgo -n flux-system                 # Ready=True
```

Run on all three clusters. If the kromgo Kustomization CR was deleted by common-apps GC (label theory wrong), IMMEDIATELY `flux reconcile kustomization kubernetes-apps` to recreate it (workloads survive regardless — they're owned by kromgo's own inventory, and a deleted parent CR without finalizer-triggered prune... if the CR deletion cascaded to workloads, redeploy happens automatically on recreate; kromgo is stateless precisely for this). Record the actual behavior — it defines the recipe for everything else.

- [ ] **Step 3: Write the recipe down.** Create `kubernetes/README.md` documenting: the tree contract (base = config once, pointers = membership), the two-PR move recipe exactly as validated (including the verified GC behavior), the verification commands, and the rule that moves are verbatim (cleanup is a separate commit). Commit to main with PR-B follow-up or directly with the wave-1 PR.

---

### Task 4: Wave 1 — unpoller + blackbox-exporter

- [ ] **Step 1: Repeat the recipe for both apps** (their layouts: `unpoller/{ks.yaml,kustomization.yaml,app/}`, `blackbox-exporter/{ks.yaml,kustomization.yaml,app/,config/}` — blackbox has TWO subdirs; check whether ks.yaml defines one or two Kustomization CRs and replicate all of them as pointers). One PR-A for both apps (adopt), live verify, one PR-B (release), live verify — exactly per the README recipe.

- [ ] **Step 2: Confirm wave outcome.** `flux get ks -A | grep -E "unpoller|blackbox"` Ready on all clusters; pods untouched; old dirs gone; `make test` green.

---

### Task 5: Spec + docs sync

- [ ] **Step 1:** Update `docs/superpowers/specs/2026-06-10-domain-ingress-repo-restructure-design.md`: in the migration-phases section mark phase 4 in progress with the pilot/wave-1 result; add a note that `StrictPostBuildSubstitutions` is a controller feature gate deferred to phase 5 (old tree must be gone first).
- [ ] **Step 2:** Update the repo `README.md` directory-structure section to show `kubernetes/` alongside `clusters/` with one line: new apps go in `kubernetes/`, old tree is migrating (link kubernetes/README.md).
- [ ] **Step 3:** Commit both to main (docs-only) or fold into the wave-1 PR.

---

## Out of scope (later waves, future sessions)

- All remaining namespaces — repeat the recipe in batches: observability/monitoring → media stacks → databases/operators (careful `dependsOn` graphs) → storage (rook-ceph LAST among apps) → tailscale/network layer (includes home→network namespace rename, NFD namespace single-ownership fix, oidc-protect component move) → flux/vars layer.
- Variable-soup cleanup per app (separate commits within waves).
- Phase 5: old-tree deletion, StrictPostBuildSubstitutions gate, CLAUDE.md/README rewrite, CONTRIBUTING.md.

## Self-review notes

- The recipe's load-bearing assumption (Flux GC skips relabeled objects) is verified empirically by the pilot BEFORE any wave; Task 3 Step 2 includes the recovery path if it's wrong, and the pilot is stateless so the worst case is a momentary kromgo redeploy.
- The duplicate-CR window between PR-A and PR-B is bounded (merge B promptly after A's verification) and affects only the Kustomization CR object, never workloads.
- flate covers both trees automatically via the entrypoint definitions in cluster.yaml — no CI changes needed.
