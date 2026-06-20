# contributing

## adding a new app

apps live in `kubernetes/apps/base/<namespace>/<app>/` — once, verbatim. see
[kubernetes/README.md](kubernetes/README.md) for the full step-by-step recipe.
the high-level flow: create the base dir, then drop a thin pointer file (a Flux
Kustomization CR) under each location tree that should run it. see
[README.md](README.md) for a walkthrough.

## exposing an app (httproute / domain)

- each cluster has a `ts`, `private`, and `public` gateway in the `home` namespace
- listeners accept `*.<CLUSTER_DOMAIN>` (e.g. `*.killinit.cc` for ottawa)
- use `${CLUSTER_DOMAIN}` in httproutes — `${COMMON_DOMAIN}` (`rajsingh.info`) is
  not routable through cluster gateways
- before creating an httproute check what hostnames the gateway accepts:
  `kubectl get gateway <name> -n home -o jsonpath='{.spec.listeners[*].hostname}'`

## auth

two options, applied per fqdn:

1. **tinyauth** — per-fqdn config, tracked in issue #1547; lightweight, no sidecar.
   This is the single auth solution for `*.keiretsu.top` web apps; the pocket-id
   `oidc-protect` component has been retired.

both are opt-in. internal tools reachable only via tailscale need neither.

## validation

```sh
make test   # flate render-test all three clusters
make diff   # show rendered diff vs origin/main
```

run `make test` before pushing. CI runs the same check. **PR diffs are
authoritative** — review the rendered output, not just the yaml source.

## repo gotchas

**flux envsubst mangles bare `$`** — drone/envsubst interprets every `$` as a
variable reference. bcrypt hashes, regexes, or any value containing `$` must
live in a Secret or ConfigMap and be injected via `${VAR}` substitution.
use \`$${VAR}\` to emit \`${VAR}\` in the rendered output (Flux translates \`$$\` → \`$\`).

**remote git-directory kustomize bases must be vendored** — flux does not
fetch remote `?ref=` bases at apply time. if a base points to an external git
path, vendor it into `kubernetes/apps/base/` first.
