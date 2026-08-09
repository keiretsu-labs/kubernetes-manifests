# Port-forward reachability is probed externally, not assumed from server selection

gluetun's `PORT_FORWARD_ONLY` filters on Proton's P2P feature bit
(`internal/provider/protonvpn/updater/iptoserver.go`), not on whether port forwarding
actually works, and its healthcheck only tests outbound reachability. A server can
therefore pass every check while forwarding a port onto an address no peer ever dials:
Proton draws the exit IP from a SNAT pool per connection, so the NAT-PMP gateway address
and the exit address sometimes differ. qBittorrent sits at `firewalled` with no error
anywhere. A `qbittorrent-portforward-probe` CronJob connects to `exit_ip:forwarded_port`
from outside the tunnel every 5 minutes and restarts the VPN via the gluetun control
server when it cannot, forcing a new draw.

## Considered options

Pinning `SERVER_HOSTNAMES` to servers observed to behave was rejected. The mismatch is
per-connection, not per-server — `node-dk-09` was measured broken and healthy within the
same hour — so an allowlist encodes a guarantee that does not exist and goes stale as
Proton renumbers. Do not "fix" the absent allowlist by adding one.

## Consequences

`WIREGUARD_ENDPOINT_IP` must stay unset: pinning it makes gluetun re-pick the same server
forever, so rotation cannot help. `/gluetun` is a `subPath` on each config PVC so the
refreshed server list survives restarts. `VPN_PORT_FORWARDING_DOWN_COMMAND` must stay
unset — pointed at the control server it deadlocks gluetun's own stop path. The probe
exits non-zero after rotating so `QbittorrentVpnRotated` can fire, and
`QbittorrentPortForwardProbeStale` covers the probe silently doing nothing.
