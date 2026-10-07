# Public Envoy: Maglev + DSR rollout (restore HA without a UniFi change)

## Status (2026-10-07): shipped, and how it differs from the plan below
All three sites now run the public Envoy on `envoy-home-public-dsr` (LoadBalancer,
`externalTrafficPolicy: Cluster`, `service.cilium.io/forwarding-mode: dsr`,
`service.cilium.io/lb-algorithm: maglev`), with 2 replicas each.

- **The one-step rename in steps O2/R2/S2 below did not work.** On Ottawa (#3451) it
  livelocked Cilium v1.20.2 with `frontend already owned by another service`, and
  #3468 reverted it. It was replaced by a **two-step handoff**:
  1. Make the old Service ClusterIP (drop `loadBalancerIP` and eTP) so it releases the VIP.
  2. Create `envoy-home-public-dsr` as LoadBalancer + DSR + Maglev with eTP Cluster.
- Shipped PRs:
  - Cilium flags: #3450 (Ottawa), #3454 (Robbinsdale), #3456 (St. Pete).
  - Handoffs: Robbinsdale #3471/#3472, St. Pete #3473/#3474, Ottawa #3490/#3491. The
    first Ottawa attempt, #3475/#3476, was rolled back by #3487/#3488 after the gate
    parser reported a false FAIL.
  - Ottawa back to 2 replicas: #3492.
  - Superseded and closed: #3451, #3453, #3455, #3457, #3480.
- **Rollback for the two-step handoff:** first revert step 2, which returns to the
  ClusterIP state, then revert step 1. Never revert both in one change, because that
  is the same-VIP handoff that livelocks.
- The client IP gate below still applies to any future eTP Local → Cluster change.

The original plan follows unchanged for reference.

Approved by Raj 2026-10-06 09:54 CT. Window: after 18:00 CT. Order: Ottawa first, then
Robbinsdale, then St. Pete.

Background: docs/agent-knowledge/ssh-public-path-investigation-20260909.md. The UDM ECMPs
the BGP-advertised public VIP (`maximum-paths 4`) and moves established WAN flows between
nodes. With eTP=Local the new node's Envoy has no socket for the flow and RSTs it. #3449
worked around this with a single public replica in Ottawa.

## Design
- `externalTrafficPolicy: Cluster`. Every node advertises the VIP and can take any flow.
- `service.cilium.io/lb-algorithm: maglev`. Every node picks the same backend for a
  5-tuple, using a shared `maglev.hashSeed` (default tableSize 16381).
- `service.cilium.io/forwarding-mode: dsr` with `loadBalancer.dsrDispatch: opt`. A node
  that receives a moved flow only DNATs it, so the backend still sees the client
  IP:port and the existing socket matches. The backend replies directly with src = VIP,
  which is what eTP=Local already does.
- Cluster defaults stay `loadBalancer.mode: snat` / `algorithm: random`. Only the public
  Envoy Service opts in.
- Feasibility (all 3 clusters): Cilium v1.20.2, native routing, autoDirectNodeRoutes,
  one L2 /24, kernel 6.18, BIG TCP.
  - `opt` is OK. For TCP the option is on the SYN only, so there is no MTU change.
  - `ipip` is impossible: it needs port == targetPort and Cilium rejects it with BIG TCP.
  - Caveat: DSR also applies to the Service's UDP 8555. Forwarded datagrams gain an
    8-byte IP option, so datagrams over 1492 B would drop. WebRTC uses about 1200 B.
- Recreating the Service is done purely through GitOps. Cilium honours the annotations
  only from creation, so the EnvoyProxy sets `envoyService.name: envoy-home-public-dsr`.
  - Envoy Gateway (v1.9.2 `createOrUpdateService`) creates the new Service and then
    `DeleteAllExcept`s the old `envoy-home-public-ea71a69f`.
  - Cilium LB-IPAM (`svcOnDelete` → `satisfyServices`) gives the pinned VIP
    (`loadBalancerIP`) to the new Service once the old one is deleted.
  - Expected blip: about 5–15s of public ingress (80/443/22/6922/8555) for that cluster.
    Live connections drop. No `kubectl delete` is needed.

## PRs
| Step | PR | What |
|---|---|---|
| O1 | #3450 | Ottawa Cilium flags: lbModeAnnotation, lbAlgorithmAnnotation, dsrDispatch opt, hashSeed, maxUnavailable 1 |
| O2 | #3451 | Ottawa public Service: rename + annotations + eTP Cluster; stays at 1 replica |
| O3 | #3453 (stacked on #3451) | Ottawa public Envoy back to 2 replicas |
| R1 / R2 | #3454 / #3455 | Robbinsdale Cilium flags, then public Service (2 replicas already) |
| S1 / S2 | #3456 / #3457 | St. Pete Cilium flags, then public Service (2 replicas already) |
| T | #3452 | public Envoy 30s not-ready/unreachable tolerations (independent; pod roll) |

Before every step:
- Check that #3449 state is healthy.
- Check that baseline memory has been captured: `/tmp/sshdbg/mem.sh baseline` on
  raj-codes.

## Step O1: Cilium agent flags (Ottawa)
1. Merge #3450 once it is green and after 18:00. Flux upgrades the HelmRelease, and
   the cilium and cilium-envoy DaemonSets roll one node at a time.
2. Watch the roll:
   - `kubectl -n kube-system get pods -l k8s-app=cilium -o wide -w`
   - `kubectl -n kube-system rollout status ds/cilium`
   - After each node: `cilium-dbg status` on the agent should show
     KubeProxyReplacement True. Also check `kubectl get ciliumbgpnodeconfigs`.
   - The UDM BGP sessions should come back (graceful restart).
3. Confirm the flags:
   - `kubectl -n kube-system get cm cilium-config -o yaml | grep -E 'bpf-lb-(mode-annotation|algorithm-annotation|dsr-dispatch|maglev-hash-seed)'`
   - `cilium-dbg status --verbose | grep -A3 'KubeProxyReplacement Details'`
4. Expect no behaviour change, because nothing carries the annotations yet. The public
   SSH smoke test must still pass.
5. Rollback: revert #3450. Agents roll back one node at a time.

## Step O2: public Service (Ottawa, still 1 replica)
1. Merge #3451. Then confirm the new Service:
   - `kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=public`
     should show only `envoy-home-public-dsr`, with EXTERNAL-IP 10.169.10.15, eTP
     Cluster and the two annotations.
   - If the new Service is still `<pending>` after 60s, roll back immediately.
2. Check the datapath on any agent:
   - `cilium-dbg service list | grep 10.169.10.15`
   - `cilium-dbg bpf lb list --frontends | grep 10.169.10.15`
   - `cilium-dbg service get <id> -o json` should show the DSR flag and the Maglev
     algorithm.
   - `cilium-dbg bpf lb maglev list` should show the tables for the new frontends.
3. The UDM now has up to 4 next hops. Moved flows hit nodes that do not host the backend
   and must be DSR-forwarded to the single Envoy. This is the real test.
4. Run the client IP gate (below) at once, then the full verification. Capture memory at +15 min and +1 h.
5. Rollback: revert #3451. EG recreates `envoy-home-public-ea71a69f` with eTP Local and no
   annotations, deletes `-dsr`, and the VIP moves back. That is the #3449 state, verified
   2026-10-06.

## Step O3: 2 replicas (Ottawa)
1. Merge the replicas PR. A second Envoy starts. Its Service and endpoints are unchanged,
   but the Maglev table now has 2 backends.
2. Verify again with the full set (below).
3. Rollback: revert. Ottawa goes back to 1 replica.

## Steps R and S: Robbinsdale, then St. Pete
For each cluster, the Cilium flags and the Service change are separate PRs, the same as O1 and O2:
- Merge the flags PR (#3454 for Robbinsdale, #3456 for St. Pete) and wait until every agent has rolled and the flags show in cilium-config.
- Then merge the Service PR (#3455 / #3457).
- Verify with Hubble and a test against that cluster's VIP. Their public SSH is not in
  DNS, so test through the site WAN :22 if it is forwarded, otherwise from a LAN host.
- Rollback: revert the Service PR, then the flags PR.

## Client IP gate (hard requirement, Kartik/Raj 2026-10-06 10:00 CT)
A public Service may only move from eTP Local to Cluster when DSR is live on that cluster and
the backend is verified to see the real external client IP. Run this immediately after each
Service PR (O2, R2, S2). If any check fails, roll back at once.
1. **Hubble (raj-codes):** every ingress flow from the WAN to the public Envoy pods on
   10022/10080/10443/8555 must have source identity `reserved:world` and the real client IP.
   - A source of `reserved:remote-node` or `reserved:host`, or a 192.168.x/10.x address,
     means SNAT.
   - With 1 replica in O2, about 3 of 4 flows enter through a node without the Envoy pod.
     Those are the DSR-forwarded ones and must still show the client IP.
2. **SSH:** for the box test sessions, the Envoy forgejo-ssh access log
   `downstream_remote_address` must be the box's public egress IP.
3. **HTTP:** `curl https://plex.killinit.cc/identity` from the box.
   - Envoy's `downstream_remote_address` and the last `x-forwarded-for` entry must be the
     box's public IP.
   - Tracearr and Plex must show real IPs for new sessions.
4. **UDP 8555:** send datagrams from the box to the site WAN:8555. Hubble must show the box
   IP as the source at the Envoy pod. Per-Service `forwarding-mode: dsr` is real DSR for UDP
   too, not hybrid, so UDP is not SNATed.
   - Datagrams over 1492 B forwarded across nodes would drop because of the IP option.
5. Not a substitute: `sessionAffinity: ClientIP`.
6. If DSR is not feasible on a cluster, that cluster keeps eTP Local. All three are feasible
   today.

Related draft PRs (need Raj's approval; after 18:00):
- #3458: gateways trust X-Forwarded-For only from 10.0.0.0/8. Today `numTrustedHops: 1` lets
  WAN clients spoof the client IP.
- #3459: Plex LoadBalancer eTP Local. Today it is Cluster and SNATs flows that land on
  non-Plex nodes.

## Verification (must pass before moving to the next step)
- **From the box over the WAN** (nohup), using the `/workspace/sshdbg/v1` harness and the
  documented client config (`nc -X connect -x %h:%p %r.bhaiya.keiretsu.top 22`):
  - 4 sessions of 40 min each: active and idle, each with `ServerAliveInterval 30` and
    with `ServerAliveInterval=0`.
  - 6 probes with 5s ticks.
  - Pass: every session exits 0 after its full duration, with no `exit 255`.
- **Hubble on raj-codes, in tmux:**
  `hubble observe --follow --to-ip 10.169.10.15 --port 22` and
  `--pod envoy-gateway-system/<public envoy pods> --port 10022`.
  - Pass: WAN flows arrive via several nodes, which is expected. Envoy sends 0 RSTs on
    flows older than 1s, and no test session dies.
- **Logs and other traffic:**
  - The Envoy forgejo-ssh access log shows no short-duration downstream RemoteReset for
    test flows.
  - HTTPS on the public hostnames returns 200.
  - UDP 8555 is reachable.
- **Memory:** run `/tmp/sshdbg/mem.sh post15` and `mem.sh post60`, then compare with the
  baseline.
  - Expected Maglev cost: tableSize 16381 × 4 B ≈ 64 KiB per Maglev frontend.
  - The public Service has 6 ports and about 5 frontends per port (LB IP, ClusterIP,
    NodePort on 0.0.0.0 and node IPs). That gives about 30 frontends, roughly 2 MiB of
    BPF memory per agent, plus a similar amount in the agent's Go heap.

## Rollback rules
- Roll back immediately if any of these happen:
  - a verification session dies;
  - the new Service has no VIP after 60s;
  - BGP does not re-establish;
  - HTTPS fails.
- Order: revert the Service PR first (it recreates the un-annotated Service), then the
  Cilium flags PR. Never remove the Cilium flags while an annotated Service exists.
- Last-resort known-good state: #3449, one replica, eTP Local.
