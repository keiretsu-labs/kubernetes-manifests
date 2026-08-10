# eks-use1 — throwaway EKS lab cluster

us-east-1 sandbox cluster for Tailscale operator / peer-relay / bandwidth
repro work. Sandbox SCP denies `ca-central-1`, so this is the closest allowed
region to Ottawa.

GitOps tree is lean on purpose: priority-classes, Tailscale operator,
slim operator resources, peer-relay (NLB), iperf client/server. Not a full
fleet overlay.

## Prerequisites

```bash
export AWS_PROFILE=tailscale-sandbox   # SSO: aws sso login --profile tailscale-sandbox
# tools: eksctl, kubectl, helm, flux, sops, gpg key FAC8E7C3...
```

## Create

```bash
eksctl create cluster -f clusters/eks-use1/bootstrap/eksctl-cluster.yaml
# ~15–25 min
```

## Bootstrap Flux + AWS LB controller + secrets

```bash
./clusters/eks-use1/bootstrap/bootstrap-flux.sh
```

Points `GitRepository` at branch `eks-use1-peer-relay-repro` by default
(see `clusters/eks-use1/flux/config/cluster.yaml`). Flip to `main` after
merge if you want this durable on main.

ACL: `tag:eks-use1` is already in `tailscale/policy.hujson`. Apply policy
before the operator can mint tagged nodes (OAuth must be allowed to own
that tag).

## Verify

```bash
tools/check.sh eks-use1
tools/kc.sh eks get nodes
flux get ks -A
kubectl -n tailscale get pods
kubectl -n tailscale-system get pods,svc
```

## Peer-relay static endpoints

NLB hostnames are not valid for `--relay-server-static-endpoints` (needs
`IP:port`). The endpoint-sync container resolves the NLB hostname and the
tailscale container applies it. If the relay comes up before the NLB has
IPs, re-apply:

```bash
EPS=$(kubectl -n tailscale-system exec eks-use1-peer-relay-0 -c endpoint-sync -- cat /shared/static-endpoint)
kubectl -n tailscale-system exec eks-use1-peer-relay-0 -c tailscale -- \
  tailscale set --relay-server-port=6969 --relay-server-static-endpoints="$EPS"
```

## Destroy

```bash
eksctl delete cluster -f clusters/eks-use1/bootstrap/eksctl-cluster.yaml --wait
# then purge leftover tailnet nodes (tag:eks-use1 / hostname eks-use1-*)
```

Or use the helper:

```bash
./clusters/eks-use1/bootstrap/teardown.sh
```

## Notes

- Flux postBuild is strict: escape shell `$` as `$$` in manifests.
- Ingress/ProxyGroup paths are userspace by default; TUN iperf numbers
  are not comparable to ProxyGroup HTTPS goodput.
- Do not leave this cluster up idle — sandbox cost.
