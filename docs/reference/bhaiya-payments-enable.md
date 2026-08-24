# Bhaiya payments enablement contract

**Status: disabled — sandbox-only preparation.**

This document records the production GitOps boundary for `bhaiya-payments` without
claiming that the service is deployable or enabled. It is intentionally the only
artifact added until the upstream service has a runnable immutable image and a
verified HTTP contract.

## Current blocker

The current `corp/bhaiya-payments` branch `feat/bhaiya-payments-contract` at
`880f844a2d66e69629a86eedede12d2a44626436` contains the provider-neutral payment
domain library and its ADR, but it does not contain:

- `cmd/payments` or another runnable service entrypoint;
- a service-specific Dockerfile/build target;
- a `payments` release-catalog row;
- a deployment, Service, probes, NetworkPolicy, migrations, or private API
  transport contract; or
- an immutable published image digest.

Therefore this repository must not add a Deployment, Service, Flux Kustomization
pointer, ExternalSecret, Secret, HTTPRoute, or placeholder image for the service.
Do not use a fake tag, `:latest`, a mutable branch tag, or plaintext provider
credentials to reserve the production name.

## Intended production placement

When the gates below are complete, the service belongs alongside Bhaiya in the
`bhaiya` namespace and is deployed only in Ottawa through a dedicated Flux child:

- workload identity: `payments`;
- intended Service DNS: `payments.bhaiya.svc.cluster.local`;
- intended application port: `8080` (HTTP/Connect contract must be confirmed by
  the service implementation before manifests are written);
- intended private caller: Bhaiya control plane, authenticated with a versioned
  service-to-service contract;
- intended state owner: the payments service's PostgreSQL schema/database and
  ordered migrations, with no direct access to Bhaiya's control-plane store;
- public route: **none**. Member/browser access remains behind Bhaiya; Stripe and
  Crater webhooks require a separately approved authenticated HTTPS route only
  after the raw-body signature and replay/idempotency behavior are implemented
  and tested.

The service must remain disabled from all active Kustomizations until it is ready.
A documentation-only contract is not a deployment and does not create the
namespace or Service DNS name.

## Enablement gates

Enablement requires all gates, in order:

1. **Runnable service:** add `cmd/payments` (or the explicitly documented
   equivalent), a bounded `/health` and readiness contract, graceful shutdown,
   metrics, and a private versioned authenticated API. Confirm the actual
   container command and listening port from the built image.
2. **Release/catalog wiring:** add the service to `corp/bhaiya-payments`'s release
   catalog with an independently buildable Dockerfile and deployment target. The
   build must publish an immutable commit-SHA image reference to the Keiretsu
   OCI registry.
3. **Image pin:** record the exact published image digest in the manifests PR
   after registry verification. A source commit or version label alone is not an
   image pin. Do not copy Bhaiya's image reference: `payments` is a separate
   process and release boundary.
4. **State contract:** provide PostgreSQL production migrations, persistence and
   idempotency behavior, migration ordering, and a backup/restore owner. Verify
   that the application consumes only its own database Secret contract and does
   not import or query Bhaiya's control-plane database.
5. **Provider secret contract:** define the ExternalSecrets backend record names
   and exact properties for Stripe, Crater, Firefly, webhook signing secrets,
   and service authentication. The backend records must exist before enabling a
   Flux pointer. No provider key, PAT, webhook secret, or password belongs in
   this repository as plaintext or a checked-in SOPS value for this service.
6. **Network policy:** allow only Bhaiya-to-payments private API traffic and
   explicitly scoped provider egress. Keep database ingress limited to the
   payments workload. Health probing must not grant general access.
7. **Sandbox verification:** exercise the service with Stripe test mode and
   disposable Crater/Firefly sandbox records: create/reuse an idempotent
   PaymentIntent, verify signed raw-body webhook intake and duplicate delivery,
   reconcile amount/currency and tenant/member mapping, and prove exactly-once
   accounting or a durable reconciliation hold. Do not create provider webhooks
   against a nonexistent production route.
8. **Production wiring:** add the base manifests, Ottawa Flux pointer, namespace
   aggregate entry, generated inventory, and repository-prescribed render/orphan
   checks in one follow-up PR. Keep the public route absent unless the final
   webhook design explicitly requires one and its auth/DNS/TLS contract is
   independently approved.

## Required follow-up artifacts

The enabling PR should include, at minimum:

- immutable `payments` image digest and source/release provenance;
- `Deployment`, `ServiceAccount`, `Service`, probes, `NetworkPolicy`, and
  `kustomization.yaml` under `kubernetes/apps/base/bhaiya/payments/`;
- an Ottawa Flux child pointer and its `kubernetes/apps/ottawa/bhaiya/` aggregate
  entry, with an explicit dependency on the payments database/Secret contract;
- ExternalSecret references containing only the verified backend record/property
  names; and
- generated inventory plus `tools/check.sh ot`, `tools/orphans.sh`,
  `tools/check-diagram.sh`, and `git diff --check` output.

Until those artifacts and gates exist, the correct production state is
**disabled and not routed**.
