# One PR merge with Flux health gate

`tools/merge-one.sh` merges one numbered PR through the kman GitHub App and checks
Flux Kustomization and HelmRelease health in Ottawa, Robbinsdale, and St.
Petersburg. It uses the repository's read-only `tools/kc.sh` wrapper. It never
reverts or changes cluster objects.

```bash
tools/merge-one.sh --pr 1234 --baseline /tmp/kman-pr-1234-before.txt
```

Pass a **new** baseline path. The command refuses to merge without the PR number
and path, or if the path already exists. It captures the not-ready set in all
three clusters and writes it before asking GitHub to merge. Keep the file with
the merge report. A failed cluster read, API call, check, or preflight leaves the
PR open. The baseline is a sorted list of `cluster/kind/namespace/name` keys;
missing or Unknown `Ready` conditions count as not ready.

The preflight permits only changes under `tools/`, `docs/`, `.renovate/`, the
root `README.md`, and `.github/renovate.json`. It rejects removed files,
Renovate-authored PRs, Held/WIP titles or labels, non-main targets, unmergeable
PRs, and any check or commit status that is not green. A PR with more than 100
changed files is also held for review. The tool checks the head and base commit
again after recording the baseline and sends the exact head SHA in the merge
request. It cannot merge a change to a running workload, a Flux object, or a
held infrastructure family.

After a successful merge, the tool waits for the `kubernetes-manifests`
GitRepository artifact and `kubernetes-apps` Kustomization to attempt the merge
SHA in each cluster. It uses read-only `kubectl wait`, with a 30-minute overall
timeout (`--timeout SECONDS` to change it). A transient `Ready=Unknown` during
reconciliation is allowed to settle. Once the root Kustomizations finish or
the timeout is reached, the tool reads Flux health again and reports newly
not-ready resources. A new failure stops the one-at-a-time merge sequence; the
operator investigates and repairs it through GitOps. If Flux never observes the
exact merge SHA, the command exits with the PR already merged and directs the
operator to inspect the clusters before merging another PR. Another commit that
supersedes the SHA can cause that timeout.

The default API helper is
`/workspace/.config/bhaiya/fleet/bin/kgh`, which authenticates as
`keiretsu-kman-bot[bot]`. `MERGE_ONE_TEST_KGH` is only for the offline tests in
`tools/tests/test_merge_one.sh`; production runs must leave it unset. Run the
offline cases with `tools/tests/test_merge_one.sh`.
