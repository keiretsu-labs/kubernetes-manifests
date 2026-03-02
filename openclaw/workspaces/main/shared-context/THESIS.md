# Thesis

Current beliefs about infrastructure and operations. Dwight reads this to shape research priorities. Every agent reads this to understand what matters right now.

## Infrastructure Philosophy

- **GitOps is the only way.** Every change goes through the repo. `kubectl apply` is for debugging, not deploying.
- **Tailscale is the network layer.** Zero-trust by default. If it's not in the ACL, it doesn't exist.
- **Self-hosting > SaaS** when the operational cost is manageable. Own the data, own the stack.
- **Three clusters, three purposes.** Robbinsdale = primary production. Ottawa = media. St. Petersburg = AI/ML. Don't mix concerns.

## Current Priorities

- Cluster stability across all three sites
- Tailscale operator integration maturity (tsdb, peer-relay, CSI provider)
- OpenClaw self-improvement loop (workspace, skills, memory)
- AI/ML workload expansion on St. Petersburg

## What Matters

- Uptime of production workloads (home-assistant, frigate, immich, media stack)
- Flux reconciliation health — if GitOps is broken, everything is broken
- Ceph storage health — data loss is unrecoverable
- Tailscale connectivity — the mesh is the backbone

## What Doesn't Matter

- Perfect formatting in PRs — substance over style
- 100% test coverage — pragmatic testing where it counts
- Keeping every service running 24/7 — some things can wait for manual restart
