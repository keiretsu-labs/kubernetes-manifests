# Certificate expiry surface (2026-10-17)

Findings-only audit of the cert-manager certificate estate: durations and
renewal windows, manual/foreign certs, and where expiry is actually detected.
No config change proposed.

## Issuers (all `ClusterIssuer`, base `cert-manager/cert-manager-common/issuers/`)

| Issuer | Type | Backs |
|---|---|---|
| `keiretsu-top` | ACME DNS-01 Cloudflare (`cnameStrategy: Follow`) | `*.bhaiya/hermes/location/s3...keiretsu.top` wildcards, keiretsu apexes |
| `keiretsu-top-nofollow` | ACME, no CNAME follow (bhaiya wildcard-shadow workaround) | `wildcard-s3-keiretsu-top` |
| `killinit-cc` | ACME DNS-01 | `wildcard-killinit-cc` (tailscale gateway, Ottawa) |
| `lukehouge-com` | ACME DNS-01 | `wildcard-lukehouge-com` (Robbinsdale) |
| `rajsingh-info` | ACME DNS-01 | `kafka-raj-tls` (Strimzi broker cert) |
| `internal` | **CA** issuer signing from Secret `kubernetes-internal-ca-key-pair` | clustermesh/Hubble trust chain (public cert copied cross-cluster via ESO; key never leaves the cluster) |

Operator: cert-manager `v1.21.2` HelmRelease, one per cluster. ACME account
keys + Cloudflare tokens all SOPS (`issuers/secret.yaml`,
`clusters/*/flux/vars`).

## Durations and renewal windows

**No `Certificate` in the tree sets `duration` or `renewBefore`** (verified:
7 Certificate manifests, 0 duration/renewBefore hits). Everything therefore
uses cert-manager defaults:

- ACME (Let's Encrypt) certs: 90-day validity, default `renewBefore` 30d —
  renewal attempted from day 60. **No cert can end up in a "<30d renewal"
  trap**: the renewal window equals the default and the shortest possible LE
  lifetime is 5× the window.
- `internal` CA-issued certs: 12-month default validity / 30d renewBefore.
  The CA itself is the long-lived object; see finding C2.

Per-certificate durations would only matter if a workload needed non-default
validity; none does. The `duration:` strings greppable in `home/local-gateway/
envoyproxy-*.yaml` are Envoy `%DURATION%` access-log tokens, not cert fields.

## Certificate inventory (7 manifests, all issuerRef → above)

- `home/local-gateway/certificate-{bhaiya,hermes,location,s3}.yaml` — public
  edge wildcards (bhaiya carries apex+wildcard SAN pair by design, documented
  inline re LE duplicate-cert rate limit).
- `home/tailscale-gateway/certificate-wildcard.yaml` — 5 certs: killinit/luke
  wildcards + internal-CA entries for tailnet names.
- `strimzi/strimzi/certificate.yaml` — `kafka-raj-tls`, mounted directly into
  the Kafka listener (`brokerCertChainAndKey`) — the one cert whose expiry is
  user-visible on a non-HTTP protocol.
- `tailscale-examples/.../derper/certificate.yaml` — `common-issuer` ref.

## Findings

| # | severity | observation |
|---|---|---|
| C1 | Info | Zero manual/foreign certs: every TLS secret served by a gateway is cert-manager-issued via the 6 ClusterIssuers; no `tls.crt`/`tls.key` literals in any non-SOPS manifest except the internal-CA pair, which is the issuer's own key material (SOPS, `issuers/secret.yaml`). |
| C2 | Low | **Single-key dependency:** `internal` CA signs from `kubernetes-internal-ca-key-pair`, which "the repo does not create" (architecture.md §cert-manager). No `SelfSigned` issuer fallback exists. If that Secret is lost, every internal/trust-domain cert is unissuable until the CA is restored from SOPS/backup. Rotation/backup procedure for that one Secret is operator territory — **NEEDS-RAJ: confirm `kubernetes-internal-ca-key-pair` is captured in the etcd/velero backup set or documented recovery path.** |
| C3 | Info | Expiry detection is external, by design: `SSLCertExpiringSoon` (<14d) / `SSLCertExpired` blackbox rules on `probe_ssl_earliest_cert_expiry` (`mimir-ottawa/rules/blackbox.yaml`) catch renewal failures on every probed endpoint. No cert-manager-metrics alert exists, but the blackbox pair covers the served surface; internal-only names (clustermesh API servers) are probed via the same `app-*` probes per architecture.md. |
| C4 | Info | ACME renewal failure visibility relies on the same 14d window; LE issues 90d certs so a stuck renewal has ~46 days of grace before C3 fires warning then error. Adequate; a `certmanager_certificate_ready_status`-based alert would be stricter but duplicates C3. |
| C5 | Info | Strimzi `kafka-raj-tls` uses the cert-manager cert directly (no Strimzi-managed CA overlap: listeners are `scram-sha-512` + supplied cert). Expiry = same C3 coverage via the kafka blackbox probe if present; no dedicated non-HTTP probe identified — lowest-risk residual, noted not actioned. |

**Verdict: no-finding requiring a PR.** Defaults are correct for every cert;
the one actionable item is the C2 backup confirmation, recorded as NEEDS-RAJ.

## Re-derive

```sh
git grep -l "kind: Certificate" -- kubernetes/ | xargs grep -c "duration:\|renewBefore"
git grep -n "issuerRef" -A3 -- kubernetes/apps/base | grep "name:"
git grep -n "SSLCert" -- kubernetes/apps/base/mimir
```
