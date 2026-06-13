# Garage Entry Point Audit

## Summary

Audited the entire kubernetes-manifests repo for all entry points into Garage. Found **2 critical** and **1 medium** issue out of ~50+ references reviewed.

---

## 🔴 CRITICAL: Agent garagekeys point at Storage tier, not Gateway tier

**Files:**
- `kubernetes/apps/base/agents/agents/app/teaspoon/garagekey.yaml` (lines 19-20)
- `kubernetes/apps/base/agents/agents/app/assistant-raj/garagekey-web.yaml` (lines 21-22)

**Current:**
```yaml
AWS_ENDPOINT_URL: "http://garage.garage.svc.cluster.local:3900"
AWS_ENDPOINT_URL_S3: "http://garage.garage.svc.cluster.local:3900"
```

**Problem:** These hardcode the **storage** tier Service (`garage`, selector `tier=storage`) instead of the **gateway** tier Service (`garage-gateway`, selector `tier=gateway`). Every other app in the repo uses `${COMMON_S3_ENDPOINT}` which resolves to `garage-gateway.garage.svc.cluster.local:3900`.

The storage service routes to storage pods (which also serve S3 incidentally), but this bypasses the gateway tier — the intended client path. Gateway pods handle key/bucket auth locally (capacity:null layout role), and going around them means:

  - Gateway pods' readiness/liveness probes won't reflect actual S3 client health
  - The `GarageGatewayUnreachable` Mimir alert won't catch outages from these agents
  - During gateway-only outages, agents keep working until something requires gateway-level auth resolution

**Fix:** Replace hardcoded `garage.garage.svc.cluster.local:3900` → `http://${COMMON_S3_ENDPOINT}`.
Note: `assistant-raj/garagekey.yaml` (the reader key) already does this correctly — only `garagekey-web.yaml` (the writer key) and `teaspoon/garagekey.yaml` are wrong.

---

## 🟡 MEDIUM: Gatus monitors Storage tier, not Gateway tier

**Files (all 3 Gatus instances):**
- `kubernetes/apps/base/gatus/gatus-ottawa/app/helmrelease.yaml` (line 515)
- `kubernetes/apps/base/gatus/gatus-robbinsdale/app/helmrelease.yaml` (line 218)
- `kubernetes/apps/base/gatus/gatus/app/helmrelease.yaml` (line 68)

**Current:**
```yaml
url: tcp://garage.garage:3900
```

**Problem:** Same pattern — probes check the storage tier (`garage`) instead of the gateway tier (`garage-gateway`). The `GarageGatewayUnreachable` Prometheus alert covers this at the operator level, but Gatus (the user-facing dashboard) only shows storage health. A gateway outage stays green in Gatus while all S3 clients fail.

**Fix:** Add duplicate Gatus checks pointing at `tcp://garage-gateway.garage:3900` to monitor the client path. Keep the storage checks too — they're useful for distinguishing storage-down vs gateway-down.

---

## 🟢 INFO: StPete Velero secondary BSL hardcodes Ottawa TS endpoint

**File:** `kubernetes/apps/stpetersburg/velero/garage-ottawa-bsl.yaml` (line 17)

**Current:**
```yaml
s3Url: http://ottawa-garage.keiretsu.ts.net:3900
```

**Assessment:** This is intentional — it's a secondary off-site backup target. The DNS name `ottawa-garage.keiretsu.ts.net` resolves via an ExternalName service that routes through Tailscale to Ottawa's garage. No change needed.

---

## ✅ CONSISTENT: Everything else

**HTTPRoutes** (5 total): All 5 HTTPRoutes referencing garage (teaspoon, raj-assistant, garage-web, garage-s3, cdn-site) correctly use `name: garage-gateway, port: 3900/3902` as their backend. These route through Envoy Gateway to the ClusterIP garage-gateway service — correct.

**COMMON_S3_ENDPOINT** (3 clusters): All 3 clusters (ottawa, robbinsdale, stpetersburg) consistently set:
```yaml
COMMON_S3_ENDPOINT: "garage-gateway.garage.svc.cluster.local:3900"
```

**Apps using COMMON_S3_ENDPOINT** (all correct):
- velero, hermes, assistant-raj (reader), abtar, kartik
- mimir, loki, kro, forgejo, zot
- tsflow (tailscale flow logs)
- immich, jellystat, tracearr (CNPG postgres backups via barman)

**Monitoring probes** (probes.yaml): Correctly checks both storage (`garage.garage:3900`) and gateway (`garage-gateway.garage:3900`) tiers with tcp_connect and http_2xx /health checks. Cross-cluster probes use ExternalName services (`ottawa-garage.garage` etc.) — correct.

**Mimir alerting rules** (3 copies): `GarageGatewayUnreachable` correctly monitors `probe_success{service="garage", tier="gateway"}` — good.

**GSLB configs:** Reference `garage-gateway` as backend — correct.

**ReferenceGrant** (agent-garage-gateway): Allows agents namespace to reference `garage-gateway` service in garage namespace — correct.

---

## Summary Table

| Area | Current | Expected | Status |
|------|---------|----------|--------|
| teaspoon/garagekey.yaml | `garage.garage.svc.cluster.local:3900` | `${COMMON_S3_ENDPOINT}` | 🔴 FIX |
| assistant-raj/garagekey-web.yaml | `garage.garage.svc.cluster.local:3900` | `${COMMON_S3_ENDPOINT}` | 🔴 FIX |
| assistant-raj/garagekey.yaml | `${COMMON_S3_ENDPOINT}` | ✓ | ✅ |
| hermes/garagekey.yaml | `${COMMON_S3_ENDPOINT}` | ✓ | ✅ |
| abtar/garagekey.yaml | `${COMMON_S3_ENDPOINT}` | ✓ | ✅ |
| kartik/garagekey.yaml | `${COMMON_S3_ENDPOINT}` | ✓ | ✅ |
| Gatus local check | `tcp://garage.garage:3900` (storage) | Add `tcp://garage-gateway.garage:3900` | 🟡 EXTEND |
| All HTTPRoutes | `garage-gateway` | ✓ | ✅ |
| COMMON_S3_ENDPOINT (3x) | `garage-gateway.garage.svc.cluster.local:3900` | ✓ | ✅ |
| Blackbox probes | Both storage + gateway | ✓ | ✅ |
| Mimir alerts | Both storage + gateway | ✓ | ✅ |
| GSLB configs | `garage-gateway` | ✓ | ✅ |
| StPete Velero BSL | `ottawa-garage.keiretsu.ts.net:3900` | intentional off-site | ℹ️ |