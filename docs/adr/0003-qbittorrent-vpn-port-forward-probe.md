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

A single unreachable result is not enough to condemn a server, because the address the
probe is testing moves underneath it. gluetun re-draws the forwarded port on any NAT-PMP
lease change or tunnel restart (`external port changed: 52095 changed to 35858`), and its
own healthcheck restarts the tunnel on its own schedule, independent of this probe. A port
gluetun has already discarded — or one belonging to a tunnel that came back seconds ago —
is unreachable for reasons that say nothing about the server. So the probe re-reads
`publicip` and `portforward` before every attempt and gives up when either moved, and it
rotates only after the same address fails two rounds a minute apart.

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

Ottawa is the only cluster that port forwards. Robbinsdale runs the same qBittorrent stack
deliberately without it, so its gluetun reports `{"port":0,"ports":[]}` and its NAT-PMP
request is refused (`10.2.0.1:5351: recvfrom: connection refused`) — expected, not a fault,
and not something to "fix" by regenerating keys or restarting pods. Its probe therefore
keeps treating a zero port as nothing to do. Only Ottawa's probe treats a persistent zero
as a failure, and even there it exits non-zero *without* rotating: a refused NAT-PMP request
is identical on every server, so rotating would restart the tunnel every 5 minutes forever.

`QbittorrentVpnRotated` counts rotations over an hour rather than testing a failed Job for
presence: `kube_job_status_failed` stays above zero for as long as `failedJobsHistoryLimit`
retains the Job, so a presence check latches the alert on for days after rotation has
converged. kube-state-metrics attaches no `cronjob` label to Job metrics, hence the
`label_replace` that derives one from `job_name`. A worst-case run now spans two rounds plus
the settle wait, so it must stay well inside the 5 minute schedule that
`concurrencyPolicy: Forbid` enforces.
