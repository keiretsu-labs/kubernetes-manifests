# kubelet serving-cert rotation config (2026-10-18)

Findings-only: per-cluster kubelet serving-certificate rotation settings in
git, the CSR approver path, and any manual-cert leftovers. No change.

## Per-cluster config (bootstrap trees)

| Cluster | kubelet patch | `rotate-server-certificates` | CSR approver |
|---|---|---|---|
| Ottawa | `all/15-kubelet.yaml:7` | `"true"` (extraArgs) | `control-plane/13-kubelet-certs.yaml` |
| Robbinsdale | `all/14-kubelet.yaml:7` | `"true"` | `control-plane/12-kubelet-certs.yaml` |
| St. Petersburg | `all/13-kubelet.yaml:7` | `"true"` | `control-plane/12-kubelet-certs.yaml` |

All three identical: Talos `rotate-server-certificates: true` puts the kubelet
into the CSR-requesting mode for its **serving** cert (client certs rotate
independently, always), and each control-plane patch adds exactly one
`cluster.extraManifests` entry:

```
https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/main/deploy/standalone-install.yaml
```

— the standalone kubelet-serving-cert-approver, so `CertificateSigningRequest`
objects with signer `kubernetes.io/kubelet-serving` are auto-approved per
node. Without an approver, `serverTLSBootstrap`-style rotation stalls with
Pending CSRs; the approver is present on every control plane.

## Drift / findings

| # | sev | observation |
|---|---|---|
| K1 | Info | No drift: identical rotation flag + approver manifest across all three clusters; per-cluster file numbering (15/14/13) matches each tree's merge-order convention. |
| K2 | Low-doc | architecture.md records `rotate-server-certificates` for Ottawa (:1891) and Robbinsdale (:1942) but the St. Petersburg kubelet bullet (:1999) omits it — one-phrase doc gap, fold into next docs pass. The yaml is correct. |
| K3 | Info | **No manual-cert leftovers**: zero `serverTLSBootstrap: false` overrides, zero static serving-cert Secrets/certs in bootstrap trees or apps; the kubelet writes its own rotating pair (see kubelet-node-credential-surface.md C3). |
| K4 | Info | The approver is a **remote raw-GitHub extraManifest** (not pinned by digest/tag) — supply-chain surface noted; standalone-install tracks main. Pinning would be a hardening PR, not a defect; recorded not actioned. |
| K5 | Info | Approval path is in-cluster (approver runs on control planes from the extraManifest) — no operator-side CSR approval runbook needed; failure mode is visible as Pending `csr` objects / kubelet auth errors. |

**Verdict: no-finding requiring action.** K2 doc gap + optional K4 pinning
noted for future lanes.

Re-derive:

```sh
git grep -n "rotate-server-certificates" -- clusters/
git grep -n "kubelet-serving-cert-approver" -- clusters/
git grep -n "serverTLSBootstrap" -- clusters/ kubernetes/   # none = no overrides
```
