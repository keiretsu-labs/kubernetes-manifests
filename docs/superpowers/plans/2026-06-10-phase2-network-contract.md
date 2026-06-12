# Phase 2: Network Contract Implementation Plan

> **STATUS: COMPLETED** — All 8 tasks verified. All-domain listeners, certs, and DNS implemented.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every gateway at every location terminates HTTPS for all four domains (keiretsu.top, killinit.cc, lukehouge.com, rajsingh.info), with one wildcard cert per domain and DNS publication for all four domains on every horizon (tailnet/LAN/public).

**Architecture:** Work happens in the existing `clusters/common` tree and `home` namespace. The three Gateways (`ts`, `private`, `public`) each gain literal per-domain wildcard HTTPS listeners replacing the `${CLUSTER_DOMAIN}` variable listener; four literal wildcard Certificates replace the variable ones. Pi-hole and UniFi external-dns get all four domains in their filters. Cloudflare external-dns instances stay per-domain (per-account credential boundary — see corrections below).

**Tech Stack:** Gateway API (Envoy Gateway), cert-manager DNS-01 via per-domain Cloudflare ClusterIssuers, external-dns 1.21.1, flate CI (from phase 1).

---

## Spec corrections discovered during planning (2026-06-10, verified live)

The phase-2 section of `docs/superpowers/specs/2026-06-10-domain-ingress-repo-restructure-design.md` has three items that change. Task 0 amends the spec.

1. **Cloudflare external-dns CANNOT collapse 4→1.** The three vanity domains live in different Cloudflare accounts (separate `KILLINIT_CC_/LUKEHOUGE_COM_/RAJSINGH_INFO_CLOUDFLARE_*` credentials — kb's, Luke's, and Raj's accounts) and external-dns accepts exactly one `CF_API_TOKEN`. The per-domain split is a credential boundary, not clutter. All 4 instances already deploy to all clusters, so the public horizon already publishes all four domains everywhere — no change needed.
2. **The Tailscale DNSConfig nameserver (`ts-dns`) is NOT orphaned — do not delete.** Each cluster's CoreDNS (`clusters/talos-*/apps/cilium/config/coredns.yaml`) forwards the `ts.net` zone to its LB IP (`<lb-prefix>.69.50`, e.g. 10.169.69.50 on ottawa, verified live). In-cluster `ts.net` resolution (egress services, cross-cluster API FQDNs) depends on it.
3. **The TS Service VIP for the ts gateway already exists.** Verified live on ottawa: the Envoy service `envoy-home-ts-*` has `loadBalancer.ingress: [{hostname: ottawa-home-envoy-gateway.keiretsu.ts.net, ip: 100.76.8.70, ipMode: VIP}]`, and tailnet split-DNS (tsddns `config.json`) already targets `svc:<location>-home-envoy-gateway`. Verify-only (Task 8).

**Other verified facts:**
- ClusterIssuer names (all deployed to every cluster via `clusters/common/apps/cert-manager/issuers/`): `killinit-cc`, `lukehouge-com`, `rajsingh-info`, `keiretsu-top`.
- Listener/cert names for each cluster's OWN domain don't change when literalized: `wildcard-${CLUSTER_DOMAIN//./-}` on ottawa already resolves to `wildcard-killinit-cc`. So each cluster sees only *additions* (2 new certs, 2 new listeners per gateway), no renames/churn for existing traffic.
- `clusters/talos-robbinsdale/apps/home/app/frigate/httproute.yaml:20,25` pins `sectionName: luke-wildcard-https`, a listener that doesn't exist (dangling parent). Fixed in Task 6.
- Listener counts after change: ts 9→11, public 11→13, private 6→8 (cap is 64).
- New ACME orders: 2 per cluster (6 total) — well inside Let's Encrypt limits.

---

### Task 0: Amend the spec with the planning corrections

**Files:**
- Modify: `docs/superpowers/specs/2026-06-10-domain-ingress-repo-restructure-design.md`

- [ ] **Step 1: Update the dns layer section**

In the "changes from today" list of the `## dns layer (target)` section, replace:

```markdown
- Collapse the four per-domain Cloudflare external-dns instances into one.
```

with:

```markdown
- Cloudflare external-dns stays one-instance-per-domain: the vanity domains live in
  different Cloudflare accounts (kb/Luke/Raj) and external-dns takes a single
  CF_API_TOKEN, so the split is a credential boundary. All four instances already run
  on every cluster, so the public horizon already covers all four domains.
```

and replace:

```markdown
- Delete the orphaned Tailscale DNSConfig nameserver (deployed, referenced by nothing).
```

with:

```markdown
- The Tailscale DNSConfig nameserver stays: each cluster's CoreDNS forwards the
  `ts.net` zone to it (cilium/config/coredns.yaml) for in-cluster MagicDNS
  resolution. The earlier "orphaned" finding was wrong.
```

- [ ] **Step 2: Update the network layer section**

In `## network layer (target)`, replace the sentence beginning "and gains a **Tailscale Service VIP**" so the bullet reads:

```markdown
- The `ts` gateway Service stays on `loadBalancerClass: tailscale` + `tailscale.com/proxy-group:
  common-ingress`, which already provisions a **Tailscale Service VIP** (verified live:
  `ipMode: VIP`, stable `<location>-home-envoy-gateway.keiretsu.ts.net` hostname). Tailnet
  split-DNS (tsddns) already targets `svc:<location>-home-envoy-gateway`. This matches
  Tailscale's official BYOD-with-Gateway-API solution doc.
```

- [ ] **Step 3: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
git add docs/superpowers/specs/2026-06-10-domain-ingress-repo-restructure-design.md
git commit -m "docs: correct phase-2 spec items (cloudflare per-account, dnsconfig load-bearing, vip already live)"
```

---

### Task 1: Four literal wildcard Certificates

**Files:**
- Modify: `clusters/common/apps/home/tailscale-gateway/certificate-wildcard.yaml` (full replacement below)

- [ ] **Step 1: Confirm issuer names**

```bash
grep -h "name:" clusters/common/apps/cert-manager/issuers/*clusterissuer.yaml | head -8
```

Expected to include: `killinit-cc`, `lukehouge-com`, `rajsingh-info`, `keiretsu-top`. If any differ, use the actual names below.

- [ ] **Step 2: Replace the file**

Replace the ENTIRE contents of `certificate-wildcard.yaml` with:

```yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-killinit-cc
spec:
  dnsNames:
    - '*.killinit.cc'
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: killinit-cc
  secretName: wildcard-killinit-cc
  usages:
    - digital signature
    - key encipherment
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-lukehouge-com
spec:
  dnsNames:
    - '*.lukehouge.com'
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: lukehouge-com
  secretName: wildcard-lukehouge-com
  usages:
    - digital signature
    - key encipherment
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-rajsingh-info
spec:
  dnsNames:
    - '*.rajsingh.info'
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: rajsingh-info
  secretName: wildcard-rajsingh-info
  usages:
    - digital signature
    - key encipherment
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-keiretsu-top
spec:
  dnsNames:
    - '*.keiretsu.top'
    - 'keiretsu.top'
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: keiretsu-top
  secretName: wildcard-keiretsu-top
  usages:
    - digital signature
    - key encipherment
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-ts-keiretsu-top
spec:
  dnsNames:
    - '*.ts.keiretsu.top'
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: keiretsu-top
  secretName: wildcard-ts-keiretsu-top
  usages:
    - digital signature
    - key encipherment
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-cdn-keiretsu-top
spec:
  dnsNames:
    - '*.cdn.keiretsu.top'
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: keiretsu-top
  secretName: wildcard-cdn-keiretsu-top
  usages:
    - digital signature
    - key encipherment
```

Why this is safe: on each cluster, `wildcard-${CLUSTER_DOMAIN//./-}` already resolved to that cluster's literal name (e.g. `wildcard-killinit-cc` on ottawa), and `wildcard-${COMMON_DOMAIN//./-}` resolved to `wildcard-keiretsu-top`. Existing Certificates/Secrets are untouched; each cluster just gains the two missing vanity-domain Certificates.

- [ ] **Step 3: Render check**

```bash
make test-talos-ottawa 2>&1 | tail -1
flate build ks --path clusters/talos-ottawa/flux/config home 2>/dev/null | grep -c "kind: Certificate"
```

Expected: tests pass; Certificate count for the home Kustomization increases by 2 vs before (6 in this file + s3 + agents elsewhere).

- [ ] **Step 4: Commit**

```bash
git add clusters/common/apps/home/tailscale-gateway/certificate-wildcard.yaml
git commit -m "home: literal wildcard certificates for all four domains on every cluster"
```

---

### Task 2: ts gateway — literal per-domain listeners

**Files:**
- Modify: `clusters/common/apps/home/tailscale-gateway/gateway.yaml`

- [ ] **Step 1: Replace the four HTTPS listeners**

In `gateway.yaml`, the listeners currently named `wildcard-${CLUSTER_DOMAIN//./-}-https`, `wildcard-${COMMON_DOMAIN//./-}-https`, and `${COMMON_DOMAIN//./-}-https` are replaced by five literal listeners. Keep `wildcard-ts-keiretsu-top-https`, `http`, `pihole-udp`, `pihole-tcp`, `forgejo-ssh` exactly as they are. The `neo4j-bolt` listener keeps its `${CLUSTER_DOMAIN}` hostname but its certificateRef becomes literal per Step 2.

The five literal HTTPS listeners (this exact block replaces the three variable ones, keeping list position at the top):

```yaml
    - name: wildcard-killinit-cc-https
      protocol: HTTPS
      port: 443
      hostname: "*.killinit.cc"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
        - group: ''
          kind: Secret
          name: wildcard-killinit-cc
    - name: wildcard-lukehouge-com-https
      protocol: HTTPS
      port: 443
      hostname: "*.lukehouge.com"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
        - group: ''
          kind: Secret
          name: wildcard-lukehouge-com
    - name: wildcard-rajsingh-info-https
      protocol: HTTPS
      port: 443
      hostname: "*.rajsingh.info"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
        - group: ''
          kind: Secret
          name: wildcard-rajsingh-info
    - name: wildcard-keiretsu-top-https
      protocol: HTTPS
      port: 443
      hostname: "*.keiretsu.top"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
        - group: ''
          kind: Secret
          name: wildcard-keiretsu-top
    - name: keiretsu-top-https
      protocol: HTTPS
      port: 443
      hostname: "keiretsu.top"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
        - group: ''
          kind: Secret
          name: wildcard-keiretsu-top
```

- [ ] **Step 2: Literalize the neo4j-bolt certificateRef**

The `neo4j-bolt` listener's certificateRef `name: wildcard-${CLUSTER_DOMAIN//./-}` still resolves correctly (same secret names), so it may stay as-is. Leave it — it's the documented "cluster-divergent hostname" exception (`cartography.${CLUSTER_DOMAIN}` is genuinely per-cluster).

Listener-name compatibility: on each cluster, the old own-domain listener name (`wildcard-killinit-cc-https` on ottawa) and the old common listener names (`wildcard-keiretsu-top-https`, `keiretsu-top-https`) are IDENTICAL to the new literal names, so any route pinning those via `sectionName: wildcard-${CLUSTER_DOMAIN//./-}-https` keeps working unchanged.

- [ ] **Step 3: Render check**

```bash
make test-talos-ottawa 2>&1 | tail -1
flate build ks --path clusters/talos-ottawa/flux/config home 2>/dev/null | python3 -c "
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get('kind')=='Gateway' and d['metadata']['name']=='ts':
        print([l['name'] for l in d['spec']['listeners']])"
```

Expected: 11 listeners, including all four `wildcard-*-https` literal names; no duplicates.

- [ ] **Step 4: Commit**

```bash
git add clusters/common/apps/home/tailscale-gateway/gateway.yaml
git commit -m "home: ts gateway terminates all four domains"
```

---

### Task 3: public gateway — literal per-domain listeners

**Files:**
- Modify: `clusters/common/apps/home/local-gateway/gateway-public.yaml`

- [ ] **Step 1: Replace the variable HTTPS listeners**

Same substitution as Task 2: replace the `wildcard-${CLUSTER_DOMAIN//./-}-https`, `wildcard-${COMMON_DOMAIN//./-}-https`, and `${COMMON_DOMAIN//./-}-https` listeners with the SAME five literal listener blocks from Task 2 Step 1 (identical YAML). Keep `http`, `wildcard-agents-${COMMON_DOMAIN//./-}-https` (literalize its name to `wildcard-agents-keiretsu-top-https` and hostname to `"*.agents.keiretsu.top"` — same resolved values), `wildcard-cdn-keiretsu-top-https`, `wildcard-s3-keiretsu-top-https`, `forgejo-ssh`, `webrtc-tcp`, `webrtc-udp` unchanged. Keep the Gateway's `external-dns.alpha.kubernetes.io/target: "${LOCATION}.${CLUSTER_DOMAIN}"` annotation and `gateway: public` label unchanged.

For the agents listener, the literal block is:

```yaml
    - name: wildcard-agents-keiretsu-top-https
      protocol: HTTPS
      port: 443
      hostname: "*.agents.keiretsu.top"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
        - group: ''
          kind: Secret
          name: wildcard-agents-${COMMON_DOMAIN//./-}
```

NOTE the certificateRef stays variable (`wildcard-agents-${COMMON_DOMAIN//./-}`) because the agents Certificate (`certificate-agents.yaml`) still uses that name — resolved value `wildcard-agents-keiretsu-top`, unchanged. Do not touch certificate-agents.yaml or certificate-s3.yaml.

- [ ] **Step 2: Render check**

```bash
make test-talos-robbinsdale 2>&1 | tail -1
flate build ks --path clusters/talos-robbinsdale/flux/config home 2>/dev/null | python3 -c "
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get('kind')=='Gateway' and d['metadata']['name']=='public':
        print(len(d['spec']['listeners']), [l['name'] for l in d['spec']['listeners'] if 'https' in l['name']])"
```

Expected: 13 listeners; https names include all four domains + agents/cdn/s3.

- [ ] **Step 3: Commit**

```bash
git add clusters/common/apps/home/local-gateway/gateway-public.yaml
git commit -m "home: public gateway terminates all four domains"
```

---

### Task 4: private gateway — literal per-domain listeners

**Files:**
- Modify: `clusters/common/apps/home/local-gateway/gateway-private.yaml`

- [ ] **Step 1: Replace the variable HTTPS listeners**

Same substitution: replace `wildcard-${CLUSTER_DOMAIN//./-}-https`, `wildcard-${COMMON_DOMAIN//./-}-https`, and `${COMMON_DOMAIN//./-}-https` with the same five literal listener blocks from Task 2 Step 1. Keep `http`, `forgejo-ssh`, and `neo4j-bolt` unchanged (neo4j keeps its `${CLUSTER_DOMAIN}` hostname + variable certificateRef). Keep the `external-dns: private` and `gateway: private` labels.

- [ ] **Step 2: Render check**

```bash
make test-talos-stpetersburg 2>&1 | tail -1
```

Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add clusters/common/apps/home/local-gateway/gateway-private.yaml
git commit -m "home: private gateway terminates all four domains"
```

---

### Task 5: Pi-hole and UniFi external-dns publish all four domains

**Files:**
- Modify: `clusters/common/apps/home/tailscale-gateway/external-dns.yaml:46-48` (domainFilters)
- Modify: `clusters/common/apps/home/local-gateway/external-dns-unifi.yaml:85-89` (domainFilters)

- [ ] **Step 1: Pi-hole instance**

In `external-dns.yaml`, replace:

```yaml
    domainFilters:
      - ${CLUSTER_DOMAIN}
      - ${COMMON_DOMAIN}
```

with:

```yaml
    domainFilters:
      - killinit.cc
      - lukehouge.com
      - rajsingh.info
      - keiretsu.top
```

- [ ] **Step 2: UniFi instance**

In `external-dns-unifi.yaml`, replace:

```yaml
    domainFilters:
      - ${CLUSTER_DOMAIN}
      - killinit.internal
      - stpetersburg.internal
      - robbinsdale.internal
```

with:

```yaml
    domainFilters:
      - killinit.cc
      - lukehouge.com
      - rajsingh.info
      - keiretsu.top
      - killinit.internal
      - stpetersburg.internal
      - robbinsdale.internal
```

Safety: txtOwnerId stays `${LOCATION}-${CLUSTER_DOMAIN//./-}` in both instances, so existing record ownership is untouched; the new filters are purely additive (routes with other-domain hostnames now publish on these horizons too).

- [ ] **Step 3: Render check + commit**

```bash
make test 2>&1 | tail -1
git add clusters/common/apps/home/tailscale-gateway/external-dns.yaml clusters/common/apps/home/local-gateway/external-dns-unifi.yaml
git commit -m "home: pihole and unifi external-dns publish all four domains"
```

---

### Task 6: Fix frigate's dangling sectionName (robbinsdale)

**Files:**
- Modify: `clusters/talos-robbinsdale/apps/home/app/frigate/httproute.yaml:20,25`

- [ ] **Step 1: Read the file and fix the parent pins**

Both `sectionName: luke-wildcard-https` references point at a listener that has never existed in the current gateway definitions (dangling parent — the route's status for that parentRef is not Accepted). Frigate is on robbinsdale (`lukehouge.com`). Replace both occurrences with:

```yaml
      sectionName: wildcard-lukehouge-com-https
```

Read the surrounding parentRefs first: if the two parents differ (e.g. one targets `ts`, one `private`), keep their gateway names — only the sectionName changes.

- [ ] **Step 2: Render check + commit**

```bash
make test-talos-robbinsdale 2>&1 | tail -1
git add clusters/talos-robbinsdale/apps/home/app/frigate/httproute.yaml
git commit -m "frigate: point route at the real lukehouge wildcard listener"
```

---

### Task 7: PR with rendered diff review

- [ ] **Step 1: Full local gate**

```bash
make test 2>&1 | grep -E "===|passed|failed"
make diff 2>&1 | head -100
```

Expected: all three clusters pass. The diff must show ONLY: new Certificates (2 per cluster), listener additions/literalizations on the three Gateways, domainFilter changes on the two external-dns HelmReleases, and the frigate sectionName fix. Any other rendered change = stop and investigate.

- [ ] **Step 2: Branch, push, PR**

```bash
git checkout -b net/phase2-all-domains   # if not already on it (this plan's commits should be made on this branch from the start)
git push -u origin net/phase2-all-domains
gh pr create --title "network: all four domains on every gateway at every location" --fill
```

Review the flate diff comments on the PR — they are the authoritative statement of what changes on each cluster. Merge when CI is green and the diff matches Step 1's expectation.

---

### Task 8: Live validation after merge

- [ ] **Step 1: Reconcile and watch certs**

```bash
for CTX in ottawa-k8s-operator.keiretsu.ts.net robbinsdale-k8s-operator.keiretsu.ts.net stpetersburg-k8s-operator.keiretsu.ts.net; do
  flux --context $CTX reconcile source git kubernetes-manifests -n flux-system >/dev/null 2>&1
  flux --context $CTX reconcile kustomization home -n flux-system --with-source=false 2>&1 | tail -1
  kubectl --context $CTX get certificate -n home -o wide | grep wildcard
done
```

Expected per cluster: 4 domain wildcards + ts + cdn (+ s3/agents) all `READY=True` within ~2 minutes (DNS-01 propagation). The two new certs per cluster go Pending→Ready.

- [ ] **Step 2: Listeners programmed**

```bash
for CTX in ottawa-k8s-operator.keiretsu.ts.net robbinsdale-k8s-operator.keiretsu.ts.net stpetersburg-k8s-operator.keiretsu.ts.net; do
  echo "=== $CTX ==="
  kubectl --context $CTX get gateway -n home -o json | python3 -c "
import json,sys
for g in json.load(sys.stdin)['items']:
    bad=[l['name'] for l in g['status'].get('listeners',[]) for c in l['conditions'] if c['type']=='Programmed' and c['status']!='True']
    print(g['metadata']['name'], 'NOT-PROGRAMMED:' if bad else 'all programmed', bad or '')"
done
```

Expected: every listener Programmed on all three gateways, all clusters.

- [ ] **Step 3: Cross-domain TLS smoke test**

Prove ottawa's ts gateway serves a valid cert for the other clusters' domains (requires tailnet):

```bash
VIP=$(kubectl --context ottawa-k8s-operator.keiretsu.ts.net get gateway ts -n home -o jsonpath='{.status.addresses[0].value}')
for d in killinit.cc lukehouge.com rajsingh.info keiretsu.top; do
  echo | openssl s_client -connect ${VIP}:443 -servername smoke.${d} 2>/dev/null | openssl x509 -noout -subject | sed "s/^/${d}: /"
done
```

Expected: each line shows `CN=*.${d}` (correct per-SNI cert). An HTTP 404 from Envoy behind a valid cert is success — no routes exist for these names yet.

- [ ] **Step 4: TS Service VIP verify (spec item, already-live confirmation)**

```bash
kubectl --context ottawa-k8s-operator.keiretsu.ts.net get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=ts -o jsonpath='{.items[0].status.loadBalancer.ingress}'
```

Expected: `ipMode: VIP` with the stable `<location>-home-envoy-gateway.keiretsu.ts.net` hostname. Record the output in the PR or commit message of a docs touch-up if anything differs.

---

## Self-review notes

- Spec coverage: phase-2 spec items map to Task 1 (certs), Tasks 2-4 (listeners), Task 5 (DNS filters), Task 8 Step 4 (VIP, verify-only); the two impossible/wrong spec items are corrected by Task 0 rather than implemented. The cdn/s3/agents/ts listeners carry over unchanged as specced.
- Live-change inventory: 2 new Certificates per cluster (new ACME orders), 2 new HTTPS listeners per gateway per cluster (additive — no existing listener name, hostname, or secret changes on any cluster), external-dns gains domains (additive, same TXT owners), frigate route pin fix (turns a dangling parentRef into an attached one — frigate becomes reachable via the wildcard listener, which is the intent of the route).
- All work should be done on branch `net/phase2-all-domains` from Task 0 onward.
