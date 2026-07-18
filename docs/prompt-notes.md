# Prompt notes — patterns that worked / failed

Running log for the orchestrator to fold into future phase prompts.

## Worked

- **State acceptance criteria explicitly** (`make test`, `kustomize build --enable-helm`).
  Agents self-verified. Keep doing this.
- **Give exact YAML file paths** to read/port. Agents respected the read-only
  boundary and used exact paths.
- **One app per run; keep phases to a few files.** Prevents context overflow.
- **`tools/check.sh` adopted by later phases** — one `✓ render OK: …` line on
  success, ~50 lines on failure. The positive signal stops agents re-running it
  to check (silent success was distrusted). Keep telling agents to use it
  instead of raw `make test`.

## Failed / costly (and the fix)

- **Re-reading large YAML/Go source files** → agents re-read Kubernetes manifests
  and Go source files many times. **Fix**: tell agents to use `tools/where.sh`
  (grep -n) to find line numbers, then read narrow offset/limit windows.
- **Long raw `make test` output dumps** → agents ran `make test` and dumped
  the full flate render output into context (~2000+ lines). **Fix**:
  `tools/check.sh` captures output and only prints ~50 lines on failure.
- **Raw `kustomize build` instead of `tools/check.sh`** → diverges from CI
  expectations. **Fix**: instruct agents to use `tools/check.sh` as their sole
  verify command.
- **No type→line map for tailscale Go files** → agents re-read 3631-line
  `tailcfg.go` 11 times. **Fix**: maintain porting-notes with Go source file
  maps for any reference sources referenced from prompts.

## Patterns to fold into future phase prompts

1. "Before reading reference sources, check `docs/` for already-distilled facts.
   Only read the specific sections you still need."
2. "Verify with `tools/check.sh` (or `tools/check.sh <cluster>`) — it runs the
   full CI gate (`make test`), prints one `✓ render OK: …` line on success /
   ~50 lines on failure. Do NOT run raw `make test` or `kustomize build`
   yourself — that dumps full output into your context. The full 3-cluster run
   can exceed a short (120s) timeout when cold; scope to the changed cluster
   (`tools/check.sh talos-ottawa`) when only one cluster changed."
3. "To find a specific section in your own files, use `tools/where.sh <pattern>
   <file>` (or `grep -n`) instead of re-reading the whole file. Only re-read
   if you need surrounding context for an edit."
4. "For any app that needs a new Helm chart source, add the HelmRepository under
   `clusters/common/flux/repositories/helm/<name>.yaml` and list it in that
   dir's `kustomization.yaml`."
5. "When adding an HTTPRoute with a `${COMMON_DOMAIN}` hostname, you MUST also
   add a CNAME entry in `kubernetes/apps/base/k8gb/k8gb-common/config/cnames.yaml`."
