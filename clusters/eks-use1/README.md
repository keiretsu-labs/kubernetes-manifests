# eks-use1 lab — read this first

Throwaway EKS cluster in **us-east-1** (sandbox SCP blocks `ca-central-1`) for
Tailscale operator / peer-relay / bandwidth repro work. GitOps is lean on
purpose — not a full fleet overlay.

Branch that carries this tree: `eks-use1-peer-relay-repro` (until merged to
`main`). Flux `GitRepository` in `flux/config/cluster.yaml` tracks that branch
by default.

## When to use this

- Peer-relay vs DERP vs direct path/throughput tests
- Operator + ProxyGroup smoke on vanilla EKS
- High-RTT / multi-path bandwidth comparisons

**Do not** leave the cluster up idle — sandbox cost. Create → measure →
`teardown.sh`.

## Spin up

```bash
export AWS_PROFILE=tailscale-sandbox
aws sso login --profile tailscale-sandbox   # if needed

eksctl create cluster -f clusters/eks-use1/bootstrap/eksctl-cluster.yaml
# ~15–25 min

./clusters/eks-use1/bootstrap/bootstrap-flux.sh
# installs AWS LB controller, Flux, sops-gpg, github token, root Kustomizations
```

SSO profile lives in `~/.aws/config` as `tailscale-sandbox` (account
`797495827785`, role `Sandbox`, region `us-west-2` default; cluster is
**us-east-1**).

## Verify

```bash
tools/check.sh eks-use1
tools/kc.sh eks get nodes
flux get ks -A
kubectl -n tailscale get pods
kubectl -n tailscale-system get pods,svc
```

`tools/kc.sh eks|eks-use1|use1` resolves the AWS kubeconfig context by name
fragment. Operator path once live: `eks-use1-k8s-operator.keiretsu.ts.net`.

## Tear down

```bash
./clusters/eks-use1/bootstrap/teardown.sh
# eksctl delete --wait + purge tailnet devices whose hostname/name contains eks-use1
```

If CFN `DELETE_FAILED` on VPC: leftover LBC security groups
(`k8s-tailscal-*`, `k8s-traffic-*`). Delete those SGs, then
`aws cloudformation delete-stack --stack-name eksctl-eks-use1-cluster`.

Confirm:

```bash
aws eks describe-cluster --name eks-use1 --region us-east-1   # should 404
tailscale status | rg eks-use1                                 # empty
```

## Layout

| Path | Role |
|------|------|
| `bootstrap/eksctl-cluster.yaml` | eksctl: 2× c5.xlarge, public nodes, OIDC |
| `bootstrap/bootstrap-flux.sh` | LBC + Flux + secrets + root apply |
| `bootstrap/teardown.sh` | destroy AWS + purge tailnet devices |
| `flux/config/cluster.yaml` | GitRepository + cluster/common/apps Kustomizations |
| `flux/vars/cluster-settings.yaml` | `LOCATION=eks-use1`, `SITE_ID=4`, CIDRs |
| `kubernetes/apps/eks-use1/` | pointers only: priority-classes, operator, system-app |
| `kubernetes/apps/base/tailscale/resources-eks/` | slim Connector/ProxyGroup/DNS (no metal LB IPs) |
| `kubernetes/apps/base/tailscale-system/tailscale-system-app-eks/` | peer-relay NLB + iperf client/server |

ACL: `tag:eks-use1` + ipset/routes/grants live in `tailscale/policy.hujson`.
Apply policy **before** the operator can mint tagged nodes (OAuth must own the
tag). OAuth client credentials come from `common-secrets` via Flux substitute.

## Gotchas (will bite you)

1. **Flux strict envsubst.** Bare `$TARGET`, `$HOST`, `$(POD_NAME)` in shell
   scripts fail postBuild. Escape as `$$`. See peer-relay StatefulSet.
2. **Static endpoints need `IP:port`.** NLB DNS names are rejected. endpoint-sync
   resolves hostname → A records; tailscale container applies
   `--relay-server-static-endpoints`. Re-apply if NLB IPs lag:
   ```bash
   EPS=$(kubectl -n tailscale-system exec eks-use1-peer-relay-0 -c endpoint-sync -- cat /shared/static-endpoint)
   kubectl -n tailscale-system exec eks-use1-peer-relay-0 -c tailscale -- \
     tailscale set --relay-server-port=6969 --relay-server-static-endpoints="$EPS"
   ```
3. **sops-gpg bootstrap secret** has cluster uid metadata in
   `clusters/common/bootstrap/flux/secret.yaml`. `bootstrap-flux.sh` strips it
   before apply — do not raw-apply that file.
4. **No Prometheus CRDs.** Do not ship PodMonitors in this overlay.
5. **Ingress ≠ TUN.** ProxyGroup/Ingress defaults to **userspace** (gVisor).
   TUN iperf numbers here are **not** comparable to ProxyGroup HTTPS goodput.
   Do not treat them as interchangeable in writeups.
6. **Peer-relay placement.** Relay next to the destination does not cut RTT for
   far clients. Lab win only when the relay shortens the path (we saw ~1 Gbit/s
   peer-relay vs ~22 Mbit/s DERP-only Ottawa↔EKS).
7. **Force DERP for comparison:** scale peer-relays to 0 **and** drop outbound
   UDP (except 53) on both endpoints — other tailnet peer-relays will otherwise
   steal the path. Restore iptables and scale back when done.
8. **Ottawa side effects.** Do not leave `ottawa-peer-relay` scaled to 0 or
   iperf/iptables hacks on `common-egress` / peer-relay pods after the session.

## Useful one-liners

```bash
# path discovery
tailscale ping -c 10 --until-direct=false eks-use1-sidecar-iperf-server-0
kubectl -n tailscale-system exec eks-use1-sidecar-iperf-client-0 -c tailscale -- \
  tailscale ping -c 10 --until-direct=false ottawa-k8s-operator

# cross-cluster iperf (server must be listening on 5201)
kubectl -n tailscale-system exec eks-use1-sidecar-iperf-client-0 -c iperf-client -- \
  iperf3 -c <ottawa-ts-ip> -p 5201 -t 15 -P 1

# operator / relay health
kubectl -n tailscale logs deploy/operator --tail=50
kubectl -n tailscale-system exec eks-use1-peer-relay-0 -c tailscale -- tailscale status
```

## Related

- Equal RTT across direct/DERP/peer-relay when the relay sits next to the
  destination is geography, not a path-selection bug. Bulk goodput on long
  paths is often high-BDP + loss, not window-scale clamp.
- `docs/reference/tailscale-integration.md` — operator/egress contracts on the
  real fleets.
- `AGENTS.md` — GitOps rules, `tools/kc.sh`, `tools/check.sh`.
