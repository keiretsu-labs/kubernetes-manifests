# TLS-SNI / non-HTTP passthrough inventory (TLSRoute/TCPRoute/UDPRoute)

Census date: 2026-10-21. Git + live read-only. Question: which names bypass the
HTTP layer (no tinyauth SecurityPolicy, no rate-limit BackendTrafficPolicy can
attach to them) and what auth they rely on instead. Complements
`route-exposure-inventory.md` (HTTP plane) — this is the L4/L4TLS plane.

## Live inventory — 5 non-HTTP route objects fleet-wide

| Route (ns) | Kind | Listeners (all Terminate-mode HTTPS or plain TCP/UDP) | Backend | Limits/auth at L4 |
|---|---|---|---|---|
| `bhaiya-ssh-mux` (bhaiya, Ottawa only) | TCPRoute | public/private/ts × `forgejo-ssh` :22 + `bhaiya-workspace-ssh` :6922 (6 parentRefs) | `bhaiya-ssh:22` | SSH keys; CONNECT authority parsed by sshmux; authZ = bhaiya V2 auth API (service cred) — in-process, not gateway |
| `frigate-webrtc-tcp` (home, Ottawa) | TCPRoute | public `webrtc-tcp` :8555 | `frigate:8555` | none — raw RTC, no auth layer exists at L4; gated by being Ottawa-only + obscurity; frigate UI itself is tinyauth'd separately |
| `frigate-webrtc-udp` (home, Ottawa) | UDPRoute | public `webrtc-udp` :8555/udp | `frigate:8555` | none (same as above) |
| `robbinsdale-broker-10/11/12`, `-bootstrap` (strimzi) | TLSRoute ×4 | **dangling** — target Gateway `private` in ns `envoy-gateway-system` + `sectionName: kafka-listener`, neither exists; documented in architecture.md | `robbinsdale-*-9092` | n/a — inert (Strimzi pointer commented out, PARKED) |

**Zero `mode: Passthrough` listeners exist**: all 20 HTTPS listeners ×3
gateways are `tls.mode: Terminate` with cert-manager secrets — every HTTPS
name terminates at Envoy and is therefore already covered by the HTTP-plane
SecurityPolicy/BackendTrafficPolicy census (10-21 #101). The only SNI-routing
surface would be TLSRoute, and the only TLSRoutes are the dangling Strimzi
four.

## Findings

**F1 — passthrough surface is minimal and fully enumerated (no-finding).**
Exactly two live bypass paths: bhaiya SSH mux (authN/Z in-process, V2 API,
key-proof gated — stronger than any gateway filter could be) and frigate
WebRTC :8555 TCP+UDP (no auth by protocol nature; WebRTC ICE/DTLS handles
peer auth; exposure = public Ottawa only, matches its documented design).

**F2 — rate limits cannot apply to L4 routes (structural, INFO).**
EnvoyGateway `BackendTrafficPolicy.rateLimit/http` and SecurityPolicy extAuth
are HTTP-layer; TCP/UDP routes have no such knobs. The only protection on
webrtc/ssh listeners is Envoy's TCP proxy defaults + listener exposure.
Acceptable: ssh is key-gated, webrtc is media-plane. Recorded so nobody
expects tinyauth on a TCPRoute.

**F3 — Strimzi TLSRoutes remain dangling (known, carried).**
The four TLSRoutes name Gateway `private`/ns `envoy-gateway-system` +
`sectionName kafka-listener` — no such Gateway/section exists (live `get
gateway -A` ×3: only `home/{private,public,ts}`). Inert while the Strimzi
pointer is PARKED (commented). If Strimzi returns, the TLSRoutes need
`namespace: home` + a real sectionName (or a dedicated kafka listener) —
recorded here; fix belongs with the unparking PR, not now.

**F4 — CF tunnel ssh-bhaiya is a third bypass (documented already).**
`ssh-bhaiya.keiretsu.top` → cloudflared → `bhaiya-ssh:22` bypasses Envoy
entirely (route-exposure-inventory.md tunnel table); auth = SSH keys + bhaiya
authz. No gateway policy applies, by design.

## Verdict

**NO-FINDING requiring change.** The non-HTTP plane is 2 live paths + 4
dangling CRs; every path has an identified auth story (in-process V2 authz /
SSH keys / DTLS) or is inert. No listener is Passthrough-mode, so no TLS name
escapes the HTTP policy plane unnoticed. No PR; census recorded.
