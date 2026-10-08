# Ottawa public DSR VIP hairpin (2026-10-08)

Ottawa pods that resolve a **public** hostname to `envoy-home-public-dsr`
(`10.169.10.15`, Maglev + DSR, `externalTrafficPolicy: Cluster`) lose
long HTTPS/TCP streams. The 2026-10-07 Woodpecker clone outage
(`curl 56 unexpected eof` / `fatal: early EOF`, ~79–85% on Ottawa agents)
is this path. Robbinsdale agents going over the WAN are fine.

## Mechanism

1. Ottawa CoreDNS/NodeLocal previously answered `forgejo.keiretsu.top` as
   `10.169.10.15` so in-cluster OAuth would not NXDOMAIN on the k8gb
   `forgejo.cdn` NS (no A glue). That pin is the hairpin.
2. A pod SYN to the VIP is **not** socket-LB'd (`bpf-lb-sock-hostns-only`).
   Traceroute hop 2 is the UDM (`192.168.169.1`). Cilium CT on the node
   shows `TCP SVC 192.168.169.1:<ephemeral> -> 10.169.10.15:443` — the
   UDM SNATs the pod source onto the VIP.
3. DSR (`bpf-lb-dsr-dispatch: opt`) makes the Envoy backend reply with
   `src = VIP` and skip the node that took the inbound SYN. The UDM NAT
   state then does not see a matching reply, so the stream dies
   mid-transfer. Small requests often succeed; git pack / slow 1.2 MiB
   downloads fail (observed: timeout after 1057775/1232206 bytes).
4. The same Service's ClusterIP (`10.2.154.170`) is also `[ClusterIP, dsr]`
   in BPF, so rewriting the hostname to that ClusterIP does **not** avoid
   DSR.
5. The private Envoy VIP (`10.169.10.14`, eTP Local, cluster-default SNAT)
   does not use DSR. HTTPS to `forgejo.killinit.cc` (already on private)
   is stable from the same pod.

Plex/Tracearr client IPs are preserved by leaving
`externalTrafficPolicy: Cluster` and the DSR annotations on the public
Service. Do not flip eTP to Local as a hairpin fix.

## Fix (GitOps, no Cilium/Envoy/BGP change)

- Pin `forgejo.keiretsu.top` to `10.169.10.14` in Ottawa CoreDNS and
  NodeLocal DNS (`cilium-ottawa/config/coredns.yaml` + `nodelocaldns.yaml`).
- Attach `HTTPRoute/forgejo-internal` (Forgejo namespace, Ottawa-only) on
  gateways `private` and `ts` so SNI `forgejo.keiretsu.top` is programmed
  on that VIP. Leave `forgejo-cdn` on `public` for WAN/k8gb.
- Public DNS (`cnames.yaml` → `ottawa.keiretsu.top`) is unchanged.

Cilium alternatives that would need an after-hours network review, and
were **not** taken:

- `loadBalancer.skipRedirectFromBackend` / SNAT for in-cluster sources
  on the DSR Service.
- Dropping DSR on the public Service (breaks the UDM-ECMP client-IP
  story that Maglev+DSR was rolled out to restore).

## Other in-cluster Ottawa clients of public hostnames on `10.169.10.15`

| Client | Hostname today | Affected? |
| --- | --- | --- |
| Woodpecker **clone** (Ottawa step pods, pre corp/bhaiya#1729) | `https://forgejo.keiretsu.top` | Yes. CI now prefers `forgejo-http.forgejo.svc`. |
| Woodpecker **server** API | `WOODPECKER_FORGEJO_URL` = in-cluster Service | No. OAuth host is still the public URL (`WOODPECKER_EXPERT_FORGE_OAUTH_HOST`); token POSTs are small. |
| Flux `GitRepository/bhaiya` | `https://forgejo.keiretsu.top/corp/bhaiya.git` | Yes for large fetches. Currently Ready; interval 10m, likely retrying. After DNS pin, clones go via private VIP. |
| Tinyauth | Forgejo OAuth callback URL in env | Callback is browser-side (WAN). |
| Bhaiya v1 (`10.3.2.23`) | CT to `10.169.10.15:443` | Yes, same hairpin. |
| Other `*.keiretsu.top` on `public` (`bhaiya`, `woodpecker`, `auth`, `grafana`, …) | Pod DNS follows public CNAME → WAN `76.71.102.41` | Hairpin **via WAN**, not the in-cluster DSR VIP. Different (and currently succeeding) path. Pin those names only if a similar EOF shows up. |
| `forgejo.killinit.cc` | private VIP `10.169.10.14` | No. |
| Robbinsdale / WAN clients | `76.71.102.41` | No. DSR is the intended WAN path. |

## corp/bhaiya#661

Same **class** (public-path mid-stream reset) as the 2026-09-09
investigation: Envoy sees `RemoteReset` from downstream. That ticket is
**WAN SSH through UniFi**, not this pod→DSR-VIP hairpin. Maglev+DSR was
the WAN-ECMP fix for that class. This hairpin is a new, in-cluster
failure mode of that same public Service. Do not treat #661 as closed
by the CoreDNS pin.

## Verify after merge (read-only)

From an Ottawa pod (e.g. `default/network-debug`):

```text
dig +short forgejo.keiretsu.top A    # expect 10.169.10.14
curl -sS -o /dev/null -w '%{http_code} %{remote_ip} %{size_download}\n' \
  --limit-rate 40k --max-time 90 --http1.1 \
  https://forgejo.keiretsu.top/assets/js/index.js
```

Expect HTTP 200, `remote_ip=10.169.10.14`, full ~1.2 MiB. CT on the
node should **not** show `192.168.169.1 -> 10.169.10.15:443` for that
flow. WAN `dig`/`curl` from outside the cluster must still hit
`76.71.102.41`.
