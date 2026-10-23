# BackendTLS / upstream-TLS verification census

Scope: git-metadata audit of `kubernetes/` + `clusters/` on `main` (ba8c61979), plus read-only cross-checks of Probe/HTTPRoute objects on all three clusters. No mutation; no chart/runtime change. Companion to `route-exposure-inventory.md` (client-facing TLS) — this is the *backend* leg.

## 1. BackendTLSPolicy objects: zero

`kind: BackendTLSPolicy` — **0 hits repo-wide** (all API versions). Corollary: no Gateway-API route in the fleet requests `https` scheme against a backend Service, and no BackendTLSPolicy exists to verify one. Every backend leg inside the cluster is plaintext HTTP:

- all 137 HTTPRoutes reference Services without `appProtocol: https` (sole `appProtocol` in-repo is `woodpecker-rb :9000 h2c` and metrics-server `https`, neither gateway-fronted);
- no `EnvoyProxy` CR sets `backendTLS` or upstream mTLS (all three CRs = accessLog/metrics/replicas only);
- remote-write (`prom-agent` → `mimir-gateway :8080`), Grafana datasources, and gatus/blackbox in-cluster targets are all `http://` URLs.

Consistency check: the internal-CA issuer (`certificate-expiry-surface.md`) signs only gateway listener certs; no serverSide/mTLS service mesh exists (no Linkerd/Istio; Cilium mTLS not enabled — no `ciliumNetworkPolicy` authentication blocks). Nothing to verify, so absence is coherent, not a gap.

## 2. insecureSkipVerify / skip-verification inventory (the "who trusts what" map)

| Consumer | Target | Mode | Evidence |
|---|---|---|---|
| blackbox `http_401` module ×3 (ott/rb/sp `app-k8s-api-*`) | kube-apiserver (`kubernetes.default.svc`, cluster-VIP `k8s.<loc>`) | **insecure_skip_verify: true** — required: cluster CA is private, not in the prober image trust store; no `ca_file` mounted (pod volumes = `config` only, live-verified) | `blackbox-exporter/app/helmrelease.yaml:40-47`, probes ×3 |
| blackbox `http_2xx_insecure` module | — | defined but **zero consumers** (dead config, Info) | `helmrelease.yaml:25-33` |
| blackbox `http_2xx` w/ https targets | `status.killinit.cc`, `1.1.1.1`, `8.8.8.8` | full verification (public LE); no tls_config override | probes-gateways/internet |
| gatus `insecure: true` ×6 | 4× kube-apiserver VIPs (`k8s.{killinit.internal,robbinsdale.local,stpetersburg.internal}` — private CA), `nas.local` (UNAS self-signed), 2× `tcp://` (n/a for TLS) | deliberate, private-CA untrusted in gatus image | gatus-{ottawa,robbinsdale,gatus} helmreleases |
| gatus verify-default ×12 | ts.net operator endpoints, public sites | system trust (LE certs) — correct | same files |
| Mimir blockstorage S3 | `${COMMON_S3_ENDPOINT}` | `insecure: true` (plain-HTTP or self-signed endpoint, in-file documented) | `mimir-ottawa/helmrelease.yaml:129` |
| TeslaMate | Postgres | `DATABASE_SSL=false` + Grafana ds `sslmode: disable` — in-cluster plain | deployment.yaml:49, grafanadataset 28 |
| teslamate/tracearr/omnibus redis clients | dragonfly | `redis://` plain, password-auth only | app.yaml |
| ESO ClusterSecretStores | kube-apiserver | `ca.crt` from `kube-root-ca.crt` ConfigMap — proper CA pin, not skip | cluster-secret-stores.yaml:83+ |
| bhaiya sync jobs / stranded-janitor / cilium clustermesh | kube-apiserver / etcd | SA `ca.crt` / generated CA secrets — proper CA pin | per-file |

No consumer sets `insecureSkipVerify` against a *public* endpoint; every skip is a private-CA or appliance endpoint where the alternative (CA pinning) would need a new mounted Secret per consumer.

## 3. caCertificateRefs-style pinning (non-Gateway-API equivalent)

No `caCertificateRefs` (field exists only on BackendTLSPolicy → none). CA pinning happens via mounted Secrets/ConfigMaps: ESO `ca.crt`, cilium clustermesh CA, bhaiya ops-bot kubeconfig CA. All pin, none skip-and-trust-any.

## Findings

- **B1 (Info)**: `http_2xx_insecure` blackbox module has zero consumers — dead config; fold its removal into the next blackbox-touching change (not worth a solo PR).
- **B2 (Info, deliberate)**: blackbox/gatus `insecure` against cluster CA endpoints is the *only* way those images can pass private-CA verification today; if ever hardened, the fix is mounting `kube-root-ca.crt`/cluster-CA + `ca_file`/gatus `client.ca` — a per-consumer change, recorded not actioned.
- **B3 (no-finding)**: no BackendTLSPolicy, no https backends, no upstream mTLS — nothing to census beyond this; the internal PKI surface is gateway-listener-only by design.

Verdict: **no-finding** — fleet-wide upstream posture is "plaintext in-cluster, verify-public-outside", with a small, deliberate insecure set (all private-CA/appliance, none public). Nothing to fix; no PR.

Backlog line 119 [x] no-finding.
