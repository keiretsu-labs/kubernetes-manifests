# Image registry provenance

Which registries the cluster's images come from, which of those are
non-official / personal, and how Renovate sees each. Audit of the git tree
(main @ `9e6138168`, 2026-10-16). Documentation only — no image or manifest
change.

## Registry census (workload images, `image:` + Helm `repository:`)

| Registry | Count | Class |
|---|---|---|
| `ghcr.io` | ~105 | mixed: upstream projects + personal orgs (below) |
| `docker.io` (+ implied) | ~120 | official upstream + 1 personal (`eceasy`) |
| `lscr.io/linuxserver/*` | 32 | community project (LinuxServer.io), 9 media images |
| `registry.k8s.io` | 12 | official Kubernetes |
| `quay.io` | 5 | official (ceph, cephcsi) |
| `oci.cdn.keiretsu.top` | 10 | **self-hosted** (Zot mirror on Garage, keiretsu) |
| `oci.cdn.${COMMON_DOMAIN}` | 1 | self-hosted, template form |

## First-party / personal images (the provenance-sensitive set)

| Image | Used by | Built from | Renovate? |
|---|---|---|---|
| `ghcr.io/keiretsu-labs/kubernetes-manifests/garage-webadmin[:sidecar]` | garage-webui (ott) | this repo's Dockerfile CI | yes (`renovate:` hints, digest-less tags) |
| `ghcr.io/keiretsu-labs/tempvm-gateway` | tempvm (ott) | repo CI | no hint |
| `ghcr.io/rajsinghtech/tailscale{,/k8s-operator,/tailscale-csi-provider}` | tailscale fork: operator values (commented), proxyclass tun-metrics build `tun-service-metrics-551eb1060@sha256`, csi-provider `:dev` | Raj's forks | **no hint on proxyclass/csi; `:dev` floats** |
| `ghcr.io/rajsinghtech/tsflow|tsk9s|tsdnsproxy|tsddns` | tailscale-examples, tsdns, tsddns cronjob | Raj's tools; tsddns has renovate hint, sha-pinned tag `sha-b500488` | 1/4 |
| `ghcr.io/kbpersonal/omnibus{,-engine}` | omnibus (media ott) | KB's builds; pinned + sha256, renovate hints present | yes |
| `ghcr.io/kbpersonal/tailscale-up-lobby:sha-48baa61` | tailscale-pam lobby | KB | no hint |
| `ghcr.io/kbpersonal/unifiwebhooktodiscord:0.1.0` | unifi-webhook (ott) | KB | no hint |
| `ghcr.io/miaai-lab/glm-5.3-flash-exl3-2x-dgx-sparks-tensorfold@sha256` (×8) | ai inference (stp) | GLM runtime, sha-pinned by hand (`upstream pin 2026-10-10` comment) | no hint (sha-only, by design?) |
| `eceasy/cli-proxy-api:v8.0.27@sha256` (×3 refs) | cliproxy | third-party personal registry `docker.io/eceasy` | no hint |
| `oci.cdn.${COMMON_DOMAIN}/kbpersonal/garage-exporter:v0.0.2` | garage-exporter (ott; retirement planned, see `docs/reference/garage-exporter-retirement-plan-20260921.md`) | KB, served from own Zot | no hint |
| `oci.cdn.keiretsu.top/corp/workspace` (×7) | bhaiya workspaces | internal CI → Zot | via `bhaiya-v2` OCIRepository, not image tags |
| `oci.cdn.keiretsu.top/keiretsu/{vault,app}:old` | mimir running-workload rule fixtures only (test data, not deployed) | n/a | n/a |

## Zot (self-hosted registry) posture

`oci.cdn.keiretsu.top` is the cluster's own registry (Zot on Garage,
`storageDriver: s3`, htpasswd auth, **anonymous read**, `ghcr.io` pull-through
mirror on 6h poll — architecture.md §Zot). Everything served from it is
first-party by construction; the mirror makes upstream blobs second-hand
copies, so provenance = upstream + our mirror.

## Renovate coverage gaps (hint-worthy, not fixed here)

Renovate reads `# renov: datasource=docker depName=<img>` hints (34 files) plus
Dockerfile/kubernetes managers. Images **without** a hint today:

1. `ghcr.io/rajsinghtech/tailscale/tailscale-csi-provider:dev` — floating
   `:dev`; a hint + real tag would make the fork trackable.
2. `ghcr.io/rajsinghtech/tailscale/tailscale` tun-metrics build in
   `proxyclass.yaml` — branch-built tag, sha-pinned; hint would at least
   document the source repo.
3. `ghcr.io/rajsinghtech/tsflow`, `-tsk9s`, `tsdnsproxy` — semver tags, no
   hints (`tsddns` is the counterexample: hinted).
4. `ghcr.io/kbpersonal/tailscale-up-lobby:sha-…`,
   `unifiwebhooktodiscord:0.1.0` — no hints.
5. `eceasy/cli-proxy-api` — third-party registry, sha-pinned; hint optional
   (digest pin may be deliberate).
6. `ghcr.io/miaai-lab/glm-…tensorfold@sha256` — sha-only by hand; a
   `renovate:` hint with the moving tag would automate the GPU runtime bump
   (worth a deliberate decision — model runtimes may want manual pins).

All are one-line comment additions; none blocks anything. Left as follow-up
candidates, not done in this docs PR.

## Provenance notes

- Every first-party image above traces to a repo CI or a named person's
  registry; no anonymous/unverified registry is in use.
- `:latest`-class floats: only `qolors/feedcord:latest` (×2, sha-commented) and
  the two `:dev`/branch tags above.
- `docker.io` library images are digested where it matters (alpine, python in
  init/render containers); app images pin version tags, several + sha256.
