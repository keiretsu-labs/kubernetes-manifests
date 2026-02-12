# Netbox Implementation Proposal

## Change ID
`netbox`

## Status
`draft`

## Summary

Deploy [NetBox](https://github.com/netbox-community/netbox) as the centralized IPAM (IP Address Management) and DCIM (Data Center Infrastructure Management) source of truth for the keiretsu-labs infrastructure. NetBox will be deployed to the **Ottawa cluster (talos-ottawa)** using the official Helm chart, backed by the existing CNPG PostgreSQL operator and Dragonfly (Redis-compatible) infrastructure already running in the cluster. A Unifi integration will synchronize device inventory from both the Robbinsdale and Ottawa Unifi controllers into NetBox.

## Problem Statement

The keiretsu-labs infrastructure spans multiple clusters (Ottawa, Robbinsdale, St. Petersburg) and sites with Unifi networking equipment at each location. Currently there is **no single source of truth** for:

- **IP address allocations** — Prefixes, VLANs, and individual IPs are tracked informally or not at all across sites.
- **Device inventory** — Unifi controllers track devices per-site but there is no unified view of all network infrastructure across all locations.
- **Cable/connection documentation** — Physical layer connectivity between devices, patch panels, and racks is undocumented.
- **Network planning** — Adding new VLANs, subnets, or devices requires manual coordination with no validation against existing allocations.

This leads to:
- IP conflicts when provisioning new services
- No visibility into which IPs are in use across sites
- Manual inventory reconciliation between Unifi controllers
- Difficulty planning network changes without a holistic view

## Proposed Solution

Deploy NetBox v4.x to the Ottawa cluster as the central network source of truth. Key aspects:

1. **Deployment**: Helm-based deployment on talos-ottawa using the [official netbox-chart](https://github.com/netbox-community/netbox-chart)
2. **Database**: Dedicated CNPG PostgreSQL cluster (following the existing pattern used by Immich, Gatus, etc.)
3. **Cache/Queue**: Dedicated Dragonfly instance (following the existing pattern used by Immich, Fleet, etc.)
4. **Unifi Sync**: CronJob running [unifi2netbox](https://github.com/mrzepa/unifi2netbox) to pull device inventory from both Ottawa (`192.168.169.1`) and Robbinsdale (`192.168.50.1`) Unifi controllers
5. **Access**: Exposed via HTTPRoute through the existing Envoy Gateway on the Tailscale and private networks

## Success Criteria

| Criteria | Measurement |
|----------|-------------|
| NetBox is running and accessible | Web UI loads, API responds at `netbox.${CLUSTER_DOMAIN}` |
| Ottawa Unifi devices synced | All devices from Ottawa controller appear in NetBox with correct site assignment |
| Robbinsdale Unifi devices synced | All devices from Robbinsdale controller appear in NetBox with correct site assignment |
| IP management functional | Can create/view prefixes, IPs, and VLANs for both sites |
| DCIM basics functional | Can view device inventory, assign rack positions, document connections |
| Existing DB pattern followed | Uses CNPG PostgreSQL cluster, not bundled PostgreSQL |
| Existing cache pattern followed | Uses Dragonfly, not bundled Redis |
| GitOps managed | All manifests in kubernetes-manifests repo, deployed via Flux |
| Backup working | PostgreSQL backups via Barman Cloud to Ceph S3 |

## Alternatives Considered

| Tool | Pros | Cons | Decision |
|------|------|------|----------|
| **NetBox** | Industry standard, comprehensive data model, excellent API, active community, Helm chart available, plugin ecosystem | Heavier than pure IPAM tools | ✅ Selected |
| **phpIPAM** | Lightweight, PHP-based, simple UI | IPAM only (no DCIM), less active development, no official Helm chart, limited API | ❌ Rejected |
| **NIPAP** | Purpose-built IPAM, good API | IPAM only (no DCIM), small community, no Helm chart | ❌ Rejected |
| **Nautobot** | Fork of NetBox, some additional features | Smaller community, diverging from NetBox ecosystem, more complex | ❌ Rejected |
| **Manual spreadsheets** | Zero infrastructure cost | Not programmatic, error-prone, no validation, no API | ❌ Rejected |

**Rationale**: NetBox is the clear choice because it covers both IPAM and DCIM in a single platform, has the largest community, the best API for automation, and an official Helm chart. The Unifi integration ecosystem (unifi2netbox, device templates) is mature.

## Scope

### In Scope
- NetBox deployment on talos-ottawa
- CNPG PostgreSQL cluster for NetBox
- Dragonfly instance for NetBox caching/webhooks
- Unifi device sync from Ottawa and Robbinsdale controllers
- HTTPRoute for web access (private/Tailscale)
- SOPS-encrypted secrets for credentials
- Basic site, device type, and prefix seeding

### Out of Scope (Future)
- NetBox plugins beyond core functionality
- Automated network provisioning from NetBox (push configs)
- St. Petersburg / GKE cluster integration (can be added later)
- Public internet exposure
- SSO/OIDC integration (can be added later)
- Cable management automation

## References

- [NetBox Documentation](https://netboxlabs.com/docs/netbox/en/stable/)
- [NetBox Helm Chart](https://github.com/netbox-community/netbox-chart)
- [unifi2netbox](https://github.com/mrzepa/unifi2netbox)
- [Ubiquiti UniFi Device Templates for NetBox](https://github.com/tobiasehlert/netbox-ubiquiti-unifi-templates)
- [Existing CNPG Pattern](../../clusters/talos-ottawa/apps/immich/app/pg.yaml)
- [Existing Dragonfly Pattern](../../clusters/talos-ottawa/apps/immich/app/redis.yaml)
