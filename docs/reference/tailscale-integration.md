# Tailscale integration reference

## Policy (`tailscale/policy.hujson`)

Central zero-trust ACL policy, deployed via GitOps
(`.github/workflows/tailscale.yml` — tests on PR, applies on merge).

**IP sets per location** (LAN / services / pods / LB / 4via6):
- Robbinsdale: 192.168.50.0/24, 10.0/10.1/10.50 /16s, fd7a:115c:a1e0:b1a:0:1::/96
- Ottawa: 192.168.169.0/24, 10.2/10.3/10.169 /16s, fd7a:115c:a1e0:b1a:0:2::/96
- St. Petersburg: 192.168.73.0/24, 10.4/10.5/10.73 /16s, fd7a:115c:a1e0:b1a:0:3::/96

**Groups:** `superuser` (kbpersonal, LukeHouge, rajsinghtech), per-location
groups, `kind` (testing). **Tags:** `infra`, `k8s-operator` (owns `k8s`),
`k8s`, `k8s-recorder`, per-location tags, `ci`.

Key grants: cross-location access via subnet routers; exit nodes per location;
K8s API impersonation (superuser/k8s → `system:masters`, members →
`tailnet-readers`); SSH everywhere for superusers/k8s with **enforced
recording** via `tag:k8s-recorder`; auto-approvers for routes/exit nodes on
`tag:k8s`; Funnel enabled for `tag:k8s`.

## Scripts (`tailscale/scripts/`)

Auth: `get-access-token.sh`, `exchange-oidc-token.sh`, `create-oauth-client.sh`,
`create-auth-key.sh`. Tailnet: `create-tailnet.sh`, `delete-tailnet.sh`,
`update-acl.sh`, `get-acl.sh`, `validate.sh`. Devices: `get-devices.sh`,
`list-devices.sh`, `manage-device.sh`, `delete-device.sh`.
`convert-hujson.sh` converts HuJSON → JSON.

`tailscale/cicd/` holds a simplified policy + kind config for the E2E operator
test (`.github/workflows/api-tailnet-k8s-test.yml` — GitHub OIDC → ephemeral
API-only tailnet → kind + operator → verify → cleanup).

## Operator deployment (`kubernetes/apps/base/tailscale-system/`)

- API server proxy with impersonation; hostname `${LOCATION}-k8s-operator`
- **Connector** — subnet router + app connector, 3 replicas, advertises LAN/
  service/pod/LB CIDRs + 4via6, exit node enabled
- **ProxyClass** `common` (metrics + ServiceMonitor), `common-accept-routes`
- **ProxyGroup** `common-egress` / `common-ingress` (3 replicas each),
  `kubernetes-${LOCATION}` for API server access
- Cross-cluster K8s API egress services per cluster operator
- **Recorder** — SSH session recording, S3 backend (DigitalOcean Spaces nyc3,
  bucket tailscale-ssh-recorder-keiretsu)
- **DNSConfig** — nameserver LoadBalancer at `${CLUSTER_LOAD_BALANCER_CIDR}.69.50`
- `tailnet-readers-view` ClusterRoleBinding for read-only tailnet users
- Custom CSI provider DaemonSet
  (`ghcr.io/rajsinghtech/tailscale/tailscale-csi-provider:dev`) — Secrets Store
  CSI auth-key mounting
- Community apps: golink, tclip (hostname `paste`), tsidp

## Pod DNS and common-egress contract

Pods do not query Tailscale MagicDNS directly. CoreDNS forwards `ts.net` to the
per-cluster Tailscale `DNSConfig` nameserver (`ts-dns` at the site's `.69.50`
LoadBalancer IP). That nameserver's records are derived from Tailscale egress
Services, not from every device in the tailnet.

Therefore every tailnet hostname consumed by a pod needs a Service in the
consumer namespace using this pattern:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: remote-node
  annotations:
    kustomize.toolkit.fluxcd.io/ssa: IfNotPresent
    tailscale.com/tailnet-fqdn: remote-node.keiretsu.ts.net
    tailscale.com/proxy-group: common-egress
spec:
  type: ExternalName
  externalName: placeholder
  ports:
    - name: rpc
      port: 3901
      protocol: TCP
```

The operator rewrites `externalName` to an internal
`*.tailscale.svc.cluster.local` proxy. `DNSConfig` simultaneously publishes the
original `remote-node.keiretsu.ts.net` name as that proxy's cluster IP. This
allows applications to keep stable tailnet names while all traffic traverses
the local `common-egress` ProxyGroup.

Operational rules:

1. Put a shared egress set in a base deployed to **every consuming cluster**.
2. Never publish `100.64.0.0/10` Tailscale addresses in Cloudflare/public DNS.
3. Never treat a successful laptop `dig` as pod-side validation; laptops use
   MagicDNS directly, pods use the DNSConfig-derived record set.
4. Before configuring a client hostname, verify both:
   - `Service.status.conditions[type=TailscaleEgressSvcReady].status == True`
   - a temporary pod resolves the original `.keiretsu.ts.net` name to the
     generated egress proxy ClusterIP.
5. For identity-authenticated protocols such as Garage RPC, create one ingress
   identity and one egress Service per remote node. A shared L4 VIP cannot route
   an expected cryptographic node ID to the correct backend.

Garage's complete storage/gateway example is under
`kubernetes/apps/base/garage/garage/{egress.yaml,egress-storage-rpc.yaml}`.

## CI workflows touching Tailscale

- `tailscale.yml` — ACL sync (gitops-acl-action)
- `api-tailnet-k8s-test.yml` — E2E operator test on ephemeral tailnet
- `delete-inactive-tailnet-nodes.yml` — tag-filtered device cleanup (default
  30 days, dry-run input)
- `claude-code-analysis.yml` — Claude agent with live cluster access via
  OIDC → Tailscale → kubectl

## Standalone egress (code pointers, tailscale repo)

- Service detection: `cmd/k8s-operator/svc.go:118` (skips ProxyGroup-annotated)
- Headless svc creation: `cmd/k8s-operator/sts.go:368-386`
- ExternalName rewrite: `cmd/k8s-operator/svc.go:313-325`
- Blanket DNAT: `cmd/containerboot/main.go:613-618` →
  `installEgressForwardingRule`; rule:
  `util/linuxfw/nftables_runner.go:179-199` (`DNATNonTailscaleTraffic`, no
  port matching); reinstalled only when `ipsHaveChanged` (`main.go:613`)
