# Operational Memory

Curated knowledge from cluster monitoring sessions. Update when you discover new patterns or recurring issues.

## Cluster Quick Facts

- Ottawa: Talos Linux, 3 nodes (rei, asuka, kaji), Rook-Ceph 3 OSDs
- Robbinsdale: Talos Linux, 5 nodes (silver, stone, tank, titan, vault), Rook-Ceph 5 OSDs
- StPetersburg: K3s, GPU-enabled, local-path-provisioner

## Common Issues

- Ceph health warnings after node restarts are usually transient — wait 5m before escalating
- Flux source-controller can lag behind webhook delivery — force reconcile if revision is stale
- Talos nodes need `talosctl` for OS-level operations, not SSH
- StPetersburg uses K3s (not Talos) — different upgrade/debug workflow

## PR Conventions

- Branch: `fix/<cluster>-<issue>` or `feat/<scope>-<description>`
- Always `gh pr list` before creating — avoid duplicate PRs
- Never push to main directly

## Skill Design Patterns

- Skill descriptions function as routing logic — include "Use when" and "Don't use when"
- cluster-health vs flux-ops vs storage-ops: negative examples clarify which to pick
- Write per-cluster findings to `/tmp/outputs/` during long scans to survive compaction
- Health report templates belong inside the skill, not in the system prompt
