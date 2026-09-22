# CLIProxy main regression handoff — 2026-09-22

Status: fixed locally; not pushed, merged, or sent through CI.

## Diagnosis

The failing contract was stale, not a regression in PR #3145. The active
St. Petersburg route is GLM-5.3 only:

- The CLIProxy `render-config` heredoc rewrites every `developer` message to
  `system` only for `vllm/GLM-5.3-Flash-EXL3`.
- `providers.yaml` exposes the `vllm/GLM-5.3-Flash-EXL3` alias with live
  `low`/`medium`/`high` thinking levels; it does not expose a Qwen route.
- The Pi synchronizer maps and overrides the same GLM route, with a
  `1048576` context window, `8192` output cap, reasoning enabled, and the
  `GLM-5.3 Flash EXL3` display name.

The Qwen-specific rewrite and assertions originated in `24949a215` and were
restored in `a3f7da625` after `5e8aeb33c` removed them as collateral. The route
then moved to GLM in `ca814bc0b`; `59b828fd06` migrated the payload rule,
provider alias, and metadata source/override to GLM. The recent 1m-profile
commits through the observed base only changed the retained `qwen38` workload
identity's GLM serving geometry in `qwen38.yaml`; they did not change
CLIProxy routing.

Conclusion: the active developer-to-system rewrite belongs to GLM-5.3, not
Qwen3.8 and not both. `tools/check-cliproxy-pi-bridge.sh` was stale and still
asserted the old Qwen alias, thinking levels, catalog ID, and metadata. No
live cluster evidence was needed; the current GitOps source and history were
unambiguous.

## Change and exact revisions

- Failing base / PR #3145 base: `adb4d7ec70cd3bfc30d0bf9cb483468068b430cd`
  (`fix(ai): reserve more headroom for 1m startup`).
- PR #3145 head: `1233d34d5973208987961c38da3882008e18b06c`
  (`test(gateway): add Bhaiya limits guardrail`). Its changes are limited to
  the Bhaiya gateway guardrail and test wiring; it does not touch CLIProxy.
- Local fix commit: `4fbe6dda71c285ed1cc5078d70dad87512781601`
  (`fix(cliproxy): align Pi bridge check with GLM route`).
- Fix range: `adb4d7ec70cd3bfc30d0bf9cb483468068b430cd..4fbe6dda71c285ed1cc5078d70dad87512781601`.

Changed files:

- `tools/check-cliproxy-pi-bridge.sh`: migrate the assertions from Qwen to
  the active GLM alias and metadata.
- `kubernetes/apps/base/cliproxy/cliproxy/app/deployment.yaml`: correct the
  adjacent explanatory comment only; the heredoc runtime rule is unchanged.

`providers.yaml`, provider aliases, metadata values, secret references, and
all AI resource geometry were intentionally left unchanged.

## Validation

- Passed: `tools/check-cliproxy-pi-bridge.sh`.
- Passed: `bash -n tools/check-cliproxy-pi-bridge.sh`.
- Passed: PyYAML parsing of the deployment, `providers.yaml`, and the embedded
  CLIProxy heredoc.
- Passed: `git diff --check`.
- Attempted: `tools/check.sh --quick`; it stopped at the pre-existing
  `kubernetes/apps/base/agent-sandbox/agent-sandbox` directory because that
  directory has no `kustomization.yaml`. No cluster render was run.

## No-mutation statement

No Kubernetes, Flux, production, or secret resources were read or mutated.
No `kubectl`, `flux`, apply/patch operation, Catan access, push, merge, or CI
rerun was performed. Only local Git files and read-only GitHub PR/user metadata
were inspected; the fix remains in this durable worktree and local commits.
