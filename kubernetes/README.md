# kubernetes/ — the new tree

apps live here exactly once; clusters opt in with thin pointer files.

```
kubernetes/
├── apps/
│   ├── base/<namespace>/<app>/        # ALL real config, exactly once (verbatim manifests)
│   └── <location>/<namespace>/        # ottawa | robbinsdale | stpetersburg
│       ├── kustomization.yaml         # lists the pointer files (+ namespace.yaml when owned here)
│       └── <app>.yaml                 # the app's Flux Kustomization CR → base path
└── components/                        # kustomize components shared across apps
```

deploy-to-some-clusters = the pointer file exists only in those location trees.
each location is reconciled by the `kubernetes-apps` Flux Kustomization
(defined in `clusters/talos-<location>/flux/config/cluster.yaml`), which injects
sops decryption + the settings/secrets substituteFrom stack into every child,
same as the old `common-apps` parent.

## moving an app out of clusters/ (the proven recipe)

the old tree already gives every app its own Flux Kustomization CR; the move
re-parents that CR without ever touching workload ownership. validated on the
kromgo pilot 2026-06-10: ownership label flips, zero pod restarts, old parent
GC skips the foreign-owned CR.

**PR-A — adopt (touches only kubernetes/):**

1. `cp -r clusters/.../​<app>/app kubernetes/apps/base/<ns>/<app>` — VERBATIM.
   no variable cleanup, no refactors. byte-identical render is what makes the
   move provably safe (cleanup is a separate commit after the move).
2. per target location: copy the app's old `ks.yaml` to
   `kubernetes/apps/<loc>/<ns>/<app>.yaml` changing ONLY `spec.path`. the CR
   `metadata.name` must stay identical — that's the adoption key. multi-CR
   apps (e.g. blackbox-exporter app+config) keep all their CRs in one pointer.
3. list the pointer in `kubernetes/apps/<loc>/<ns>/kustomization.yaml`.
4. prove it: `make test`, then byte-identical check —
   `flate build ks --path clusters/talos-ottawa/flux/config <app>` before/after
   (git stash) must diff empty.
5. merge, then per cluster: reconcile `kubernetes-apps`, confirm
   `kubectl get kustomization <app> -n flux-system` shows
   label `kustomize.toolkit.fluxcd.io/name: kubernetes-apps` and the new path,
   and the app's pods kept their start times.

**PR-B — release (touches only clusters/):**

6. `git rm -r clusters/common/apps/<app>` (or the cluster-specific dir). the
   old parent auto-discovers by directory, there is no registration list.
7. merge, reconcile `common-apps`, confirm the CR still exists, pods
   untouched, `flux get ks <app>` Ready. flux GC skips objects whose ownership
   labels were taken by another Kustomization — that's the safety mechanism.

keep the A→B window short (hours): during it both parents apply the same CR
and the ownership label can flap. never batch A and B into one PR.

## namespaces

when an app's namespace is owned by the old tree, move the `namespace.yaml`
into `kubernetes/apps/<loc>/<ns>/` in PR-A (listed in that kustomization) and
keep its `kustomize.toolkit.fluxcd.io/prune: disabled` label. one tree must
own each namespace — never both for longer than the A→B window.

## validation

every PR touching `kubernetes/**` or `clusters/**` gets flate render tests and
per-cluster rendered-diff comments. a move PR-A must show ONLY the CR path
change; anything else in the diff means the copy wasn't verbatim.
