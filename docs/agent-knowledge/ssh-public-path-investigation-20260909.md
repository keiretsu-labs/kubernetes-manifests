# Public-path SSH drops — investigation state (2026-09-09)

This is the current state of the public Bhaiya SSH investigation. It records
what the cluster-side evidence has eliminated and the one remaining test that
requires access to the UniFi gateway. It is not a claim that the UniFi device
has been proven faulty.

## Conclusion

The reset is downstream of Envoy. All 17 of 17 matched disconnects were
`RemoteReset` at Envoy: Envoy received the reset from its downstream peer and
closed its upstream side normally. Envoy is therefore a bystander at the
observed reset boundary, not the identified source.

The in-cluster stateful limits and transport theories listed below are
eliminated. The remaining public-path hypotheses are UniFi NAT/flow state and
hardware or flow offload. The UniFi API exposes no live flow telemetry, showed
no counter discontinuity at the failure times, and offers no per-rule offload
disable. A global offload toggle is the only available discriminator.

## Eliminated

| Candidate | Evidence | Result |
| --- | --- | --- |
| Envoy as the reset source | All 17/17 disconnects were `RemoteReset` downstream of Envoy, with the reset arriving from the next hop. | **Eliminated as the source.** Envoy remains part of the path, but its record places the RST downstream. |
| Node Linux conntrack capacity | The Ottawa node's conntrack capacity had headroom. | **Eliminated.** |
| Node Linux conntrack utilisation | `nf_conntrack_count` stayed low relative to `nf_conntrack_max`; drop and insert-failure counters did not increment, and kernel logs had no `nf_conntrack: table full, dropping packet`. | **Eliminated.** |
| Cilium conntrack capacity/utilisation | Cilium CT maps peaked at 26.3%, with reverse-NAT lower; utilisation was approximately 1% at and after the failure timestamps. | **Eliminated.** |
| Envoy connection limits | The observed drops did not coincide with an Envoy connection-limit condition. | **Eliminated.** |
| Keepalive or idle eviction | The keepalive/idle-eviction explanation was tested and refuted three times. It does not explain the active slow-drip failures. | **Eliminated.** |
| Fixed duration or byte boundary | Public-path failures have not shown a stable elapsed-time or accumulated-byte cutoff. Earlier matched durations ranged from 2:54 to 13:45; later identical-path trials on 2026-09-09 06:54–06:55 lasted 4s, 81s, and a full 179s survival. | **Eliminated as a simple fixed boundary.** No particular byte count is an established trigger. |
| Shared-port/protocol rule shape | Raj split port 22 into a single-protocol TCP forward. The issue persisted: 6 failures and 1 survival across 7 trials, including 0/4 controlled runs. | **Eliminated as the fix.** Changing the port-22 rule shape did not remove the fault. |
| SSH-specific handling | Public HTTPS 443 also fails during a long slow-drip flow, while the equivalent Tailscale path survives indefinitely. | **Eliminated.** The symptom crosses protocols and is specific to the public path, not SSH. |

The duration and byte result is important: a trial that happens to last longer
does not establish a timeout threshold. The observed variance is compatible
with state that is created, exhausted, or recovered in the public path, but it
does not identify which stateful device is responsible.

## Remaining hypotheses

Only these public-path explanations remain actionable:

1. UniFi NAT or flow state is being evicted, exhausted, or otherwise mishandled.
2. UniFi hardware/flow offload is mishandling an established flow.

The read-only UniFi API showed no counter discontinuity at a failure time. That
does not exonerate either hypothesis because it provides neither per-flow
telemetry nor historical state sufficient to attribute a reset. Further
cluster-side conntrack, Cilium, or Envoy checks will not distinguish them.

## Working reproduction

Use Raj's existing external slow-drip harness through the public path, for
example the long-lived public attach:

```text
herdr --remote ssh://raj-codes@bhaiya.keiretsu.top
```

Run it from outside the cluster through the same public SOCKS/UniFi path used
for the failing trials. Do not run it from inside the cluster or through a
hairpin: that changes the path and invalidates the comparison. Keep the
endpoint, slow-drip workload, and traffic rate unchanged; record UTC start and
end times, protocol, completion/reset outcome, and byte totals. The same path
must be capable of producing both a reset and a survival, as demonstrated by
the 4s, 81s, and 179s trials above. The equivalent public HTTPS 443 slow-drip
test is the cross-protocol control.

Two harness traps invalidated earlier runs:

1. The completion marker matched SSH's own command echo. Before counting a
   completion, filter lines matching:

   ```text
   ^debug|Started with|Sending command
   ```

2. A remote test dies with the `tailcat` session unless it is run
   synchronously. Do not background it and assume the session will keep it
   alive; `setsid` is not available on macOS. Invoke the remote test
   synchronously and wait for its actual result.

## UniFi offload A/B test

This is a maintenance-window test for Raj. It must be run from an external
client over the public path, never via an in-cluster hairpin.

1. Record the baseline before changing anything: the current global offload
   setting, one or more results from the SSH and HTTPS slow-drip reproductions,
   gateway CPU and memory, WAN/LAN throughput, and packet loss/latency. The
   gateway is already around 75% memory, so include resource measurements in
   the decision record.
2. Disable the UniFi gateway's **global hardware/flow offload** setting. Do not
   change the port-22 forward or any protocol rule. There is no per-rule
   offload switch.
3. Repeat the same external SSH and HTTPS slow-drip trials with the same
   endpoints and workload. Record the same timestamps, completion/reset result,
   byte totals, gateway resource use, throughput, latency, and packet loss.
4. Restore the original offload setting after the comparison if it is not
   being left disabled as an approved operational change. Record the setting
   and the before/after results together.

The cost is global: gigabit forwarding moves to the gateway CPU and a
network-wide throughput drop is expected while offload is disabled. This is
not a harmless per-rule experiment; schedule it with users informed and watch
CPU, memory, throughput, latency, and loss during the window.

Both outcomes are useful:

- If the public-path failures stop with offload disabled, hardware fast-path
  handling is implicated. That is a strong A/B result for the remaining
  hypothesis, though it does not by itself identify the exact offload table or
  flow-state defect.
- If the failures continue, hardware/flow offload is exonerated for this
  symptom. The public path then needs a different theory, principally UniFi
  NAT/state behaviour or an upstream/WAN path problem; do not keep repeating
  cluster-side conntrack tests.

## Current mitigation and ownership

For a working connection today, swap the SOCKS hop to the Tailscale IPv4
literal `100.76.8.70` while retaining the Bhaiya workspace authority used by
the mux. The Tailscale hop survives indefinitely in the observed comparison.
This is a workaround, not a repair: it requires tailnet access and leaves the
public path broken for other users. `corp/bhaiya #661` and `corp/bhaiya #343`
therefore remain open.

The next discriminating action is Raj's UniFi offload A/B test. No further
in-cluster candidate remains open on the evidence above.

## Corroboration — Kartik public SSH kicks (2026-10-05)

Kartik's interactive `kartik-codes` Herdr session on public `:22` was kicked
while actively typing (~5:12 PM CT). Same day, an in-box active soak
(`while true; do date; sleep 5; done` with `ServerAliveInterval 15`) died at
~150s with `Connection closed by remote host` / `Broken pipe`.

Matched Envoy `forgejo-ssh` records on `envoy-home-public…6txdx` (rei):

| start (UTC) | duration | close | peer | notes |
| --- | ---: | --- | --- | --- |
| 21:59:01 | 133943 ms | RemoteReset/Normal | 68.67.47.152 | Kartik; bhaiya `client_close` 133161 ms, 4 keepalives |
| 22:01:26 | 75900 ms | RemoteReset/Normal | 68.67.47.152 | Kartik |
| 22:03:18 | 453740 ms | RemoteReset/Normal | 68.67.47.152 | Kartik survived ~7.5 min once |
| 22:16:40 | 150406 ms | RemoteReset/Normal | 3.217.165.30 | box active soak |

Ruled out for this incident (same day):

- idle timeout / missing keepalives (`BHAIYA_SSH_KEEPALIVE_INTERVAL=30s`; soak was active every 5s);
- Envoy/bhaiya-ssh restarts (public Envoy 6d up, 0 restarts; bhaiya-ssh stable for hours);
- V2 SSH authz recheck (0 `session_recheck` failures; terminations are `client_close`/`read_eof`, not `authorization_unavailable`);
- fixed 120s route/`max_connection_duration` (durations 24s–453s; one Envoy idle close was `tcp_session_idle_timeout` at ~1h).

`externalTrafficPolicy` remains `Local` after #2980. The :22-only cutover
(#3402, 2026-10-04) removed the dedicated `bhaiya-workspace-ssh` :6922
listener that was the preferred durable workspace path; clients fell back onto
public `:22` / UniFi WAN:22 and re-hit this RemoteReset signature. Restore
:6922 as the preferred workspace entrypoint (Gateway listener + TCPRoute
parentRef); keep `:22` for Forgejo + legacy CONNECT. UniFi must still forward
WAN:6922 → `10.169.10.15:6922`. Tailscale `100.76.8.70` remains the working
client workaround if public :6922 is not yet forwarded.

## Packet capture — UniFi-sourced forged client RST (2026-10-05)

Read-only capture on Ottawa node `rei` (`bond0`, hostNetwork) during a
reproduced public `:6922` active soak from the agent box
(`while true; do date; sleep 5; done`, `ServerAliveInterval 15`).

| Field | Value |
| --- | --- |
| Flow | `32.192.134.193:1135 → 10.169.10.15:6922` |
| Envoy | `bhaiya-workspace-ssh`, start `22:36:06.334Z`, dur `130909` ms, `RemoteReset/Normal` |
| Client symptom | `Connection closed by remote host` / `Broken pipe` at `22:38:17Z` |
| Ethernet src of RST | `94:2a:6f:f6:4b:25` = UniFi LAN gateway `192.168.169.1` (ARP) |
| Ethernet dst | `38:05:25:36:56:39` = `rei` |
| RST IP | `id=0`, `ttl=114`, `win=0`, no TCP options, length 40 |
| Preceding client data IP IDs | `35404`…`35407` (incrementing) on the same 5-tuple |
| Immediate prelude | server retransmit of `seq 4340:4400` at `22:38:16.985` and `22:38:17.220`, then RST |

**Interpretation.** Every client→server frame on this flow (SYN, data, ACK,
RST) arrives from the UniFi MAC — expected for WAN-sourced traffic. TTL `114`
is the path TTL (same on SYN/data/RST) and does **not** by itself prove
forgery. The kill packet’s **IP ID reset to 0** while the live flow was in the
`3540x` range, plus bare `win=0` RST with no options, is inconsistent with the
same end-host stack that had been sending data. Combined with Envoy
`RemoteReset` and the client seeing a remote close, this matches a
**middlebox dual-RST**: UniFi (or its offload engine) aborts the flow and
emits an RST toward the VIP that spoofs the client address.

Prior read-only UniFi API work already found IPS/advanced filtering off and a
7440s TCP session timeout — so those are not the timer. Hardware/flow offload
remains the leading UniFi feature to A/B (no per-rule switch; global only).

### What this is not

- Not Envoy generating the RST (`RemoteReset` + upstream `Normal`).
- Not Cilium/node conntrack exhaustion (previously eliminated).
- Not workspace pod OOM/sshd (kartik-codes: 0 restarts, no OOM; architecture
  has no in-pod sshd).
- Not fixed by restoring `:6922` alone — same public VIP/UniFi path; this
  capture was on `:6922`.

### Separate bug (do not conflate)

Changing Gateway listeners / EnvoyProxy access-log blocks triggers an Envoy
reload that can purge live TCPRoute sockets
(`purging_socket_that_have_not_progressed_to_connections` on ts Envoy during
the 2026-10-05 `:6922` restore). That killed a Tailscale SSH at ~`22:29Z`.
**Do not change public/ts Gateway listeners during working hours** until drain
preserves established TCP connections.

### Fix options (ordered)

1. **UniFi (needs Raj, not GitOps):** disable global hardware/flow offload,
   soak public SSH/HTTPS, then re-enable if needed. Exact UI path varies by
   UniFi OS version; on current UniFi Network / UniFi OS gateways look under
   **Settings → System / Advanced** (or **Internet / Network Acceleration**)
   for **Hardware Offload** / **Flow Offloading** / **Network Acceleration**.
   Rollback = re-enable the same toggle. Expect CPU forwarding cost and lower
   multi-gig throughput while off.
2. **GitOps-only public path that avoids UniFi WAN DNAT:** terminate SSH on an
   outbound tunnel (Cloudflare Tunnel private TCP origin, or Border0 SSH
   socket) and publish `ssh.bhaiya.keiretsu.top` (or Spectrum in front of the
   tunnel). Cloudflare Spectrum pointed at the public WAN IP alone still
   traverses UniFi port-forward and does **not** fix this.
3. **Client workaround:** Tailscale `100.76.8.70:6922` (ts Envoy) for users on
   the tailnet — bypasses UniFi WAN; still subject to Envoy reload purges.
