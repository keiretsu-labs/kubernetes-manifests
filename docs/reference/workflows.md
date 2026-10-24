# GitHub Actions workflow index

One line per workflow in `.github/workflows/`: trigger, purpose, and whether it
participates in the required-check pair (`validate` + `flate-gate`, enforced by
the merge-queue ruleset — only those two workflows run on `merge_group`).

Generated-by-hand table, kept in step with the tree; `architecture.md`
§Workflows carries the prose map, this is the lookup table.

| Workflow (file) | `name:` | Triggers | Jobs | Purpose | Merge-queue |
| --- | --- | --- | --- | --- | --- |
| `api-tailnet-k8s-test.yml` | API-Only Tailnet with Kubernetes Operator Test | dispatch | 1 | Ephemeral-tailnet operator E2E for this repo's tailscale config | – |
| `aqua-checksums.yaml` | aqua-checksums | PR (renovate), push, dispatch | 2 | Regenerate/verify `aqua-checksums.json`; dispatches follow-up validation on renovate heads | – |
| `border0.yml` | Border0 sockets | push, PR, dispatch | 1 | Border0 socket/tunnel config drift check | – |
| `cliproxy-pi-bridge.yaml` | cliproxy-pi-bridge | push, PR, dispatch | 1 | Structural contract check for the cliproxy pi-bridge manifests | – |
| `delete-inactive-tailnet-nodes.yml` | Delete Inactive Tailnet Nodes | dispatch | 1 | Tag-filtered tailnet device reaping | – |
| `diagram.yaml` | architecture diagram | PR, push, dispatch | 1 | `tools/check-diagram.sh` + SVG artifacts | – |
| `domain-dns.yaml` | domain dns coverage | PR, push, dispatch | 1 | Gateway-listener ↔ DNS-plane parity gate | – |
| `flate.yaml` | flate | push, PR, **merge_group**, dispatch | 7 | Render matrix, sticky per-cluster diff comments, self-tests, fixtures; hosts required `flate-gate` | **yes** |
| `garage-webadmin-build.yaml` | Build & Push Garage WebAdmin Image | push, dispatch | 1 | Build/publish webadmin image to GHCR | – |
| `garage-webadmin-sidecar-build.yaml` | Build & Push Garage WebAdmin Sidecar Image | push, dispatch | 1 | Build/publish sidecar image to GHCR | – |
| `label-sync.yaml` | Label Sync | push (labels.yaml), dispatch | 1 | Enforce `.github/labels.yaml` as the label source of truth | – |
| `renovate-inventory.yaml` | Renovate inventory | pull_request_target (renovate) | 1 | Bot-regenerate `docs/reference/inventory.md` on app-tree PRs | – |
| `tailscale-full-config-status.yml` | Tailscale Status Check | dispatch | 1 | Read-only tailnet full-config state report | – |
| `tailscale.yml` | Sync Tailscale ACLs | push, PR | 1 | Apply `tailscale/policy.hujson` to the tailnet | – |
| `test-arc-runner.yaml` | Test ARC Runner | dispatch | 1 | Actions-runner-controller smoke test (`arc-runner` label) | – |
| `token.yml` | – | dispatch | 1 | Tailscale OIDC token-exchange probe (masks + redaction tested) | – |
| `validate.yaml` | Validate YAML | PR, PR(target), **merge_group**, dispatch | 1 | YAML parse + renovate-dispatch guard; required `validate` | **yes** |
| `version-sync.yaml` | version-sync | push, PR, dispatch | 1 | `tools/check-versions.sh` coupled-version gate | – |
| `webtop-bot-build.yaml` | Build & Push Webtop Bot Image | push, weekly cron Mon 07:00, dispatch | 1 | Build/publish maintainer webtop images | – |

Notes:

- Only `validate` and `flate-gate` (job of `flate.yaml`) are repository-required
  check runs; everything else is informational or path-scoped.
- Dynamic `dynamic/*` workflows are created by GitHub's dependency graph
  (dependabot), not stored in this repo.
- Retired workflows (`release.yaml`, `devcontainer.yaml`) were removed in
  #3866; the vestige-pair rationale lives in the PR history.
