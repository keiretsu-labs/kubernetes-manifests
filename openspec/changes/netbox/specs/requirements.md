# Netbox Requirements

## Functional Requirements

### FR-1: IPAM — IP Address Management

| ID | Requirement | Priority |
|----|------------|----------|
| FR-1.1 | Manage IP prefixes (subnets) for all sites with hierarchy support | Must |
| FR-1.2 | Track individual IP address assignments with status (active, reserved, deprecated) | Must |
| FR-1.3 | Define and manage VLANs with VLAN group support per site | Must |
| FR-1.4 | Support VRF (Virtual Routing and Forwarding) instances for network segmentation | Should |
| FR-1.5 | Enforce unique IP space within global table (`enforceGlobalUnique: true`) | Must |
| FR-1.6 | Support prefix and IP address roles (e.g., Loopback, P2P, Management) | Should |
| FR-1.7 | Provide available IP detection within prefixes | Must |
| FR-1.8 | Support DHCP range documentation within prefixes | Should |

#### Known Prefixes to Seed

| Site | Prefix | VLAN | Purpose |
|------|--------|------|---------|
| Ottawa | `192.168.169.0/24` | - | LAN |
| Ottawa | `10.3.0.0/16` | - | Pod CIDR |
| Ottawa | `10.2.0.0/16` | - | Service CIDR |
| Ottawa | `10.169.0.0/16` | - | LoadBalancer CIDR |
| Robbinsdale | `192.168.50.0/24` | - | LAN |
| Robbinsdale | `10.1.0.0/16` | - | Pod CIDR |
| Robbinsdale | `10.0.0.0/16` | - | Service CIDR |
| Robbinsdale | `10.50.0.0/16` | - | LoadBalancer CIDR |

### FR-2: DCIM — Data Center Infrastructure Management

| ID | Requirement | Priority |
|----|------------|----------|
| FR-2.1 | Define sites (Ottawa, Robbinsdale, St. Petersburg) with physical addresses and GPS coordinates | Must |
| FR-2.2 | Model racks with unit positions at each site | Should |
| FR-2.3 | Track devices (switches, APs, UDMs, servers) with manufacturer, model, serial number | Must |
| FR-2.4 | Support device roles (Router, Switch, Wireless AP, Server, Storage) | Must |
| FR-2.5 | Model device interfaces (physical ports, LAGs, VLANs) | Must |
| FR-2.6 | Document cable connections between devices | Should |
| FR-2.7 | Support device types with port templates from Ubiquiti device template library | Must |
| FR-2.8 | Track device status (active, planned, staged, decommissioning) | Must |
| FR-2.9 | Support platform definitions (Talos Linux, UniFi OS, TrueNAS, etc.) | Should |

### FR-3: Unifi Integration

| ID | Requirement | Priority |
|----|------------|----------|
| FR-3.1 | Sync devices from Ottawa Unifi controller (`192.168.169.1`) into NetBox | Must |
| FR-3.2 | Sync devices from Robbinsdale Unifi controller (`192.168.50.1`) into NetBox | Must |
| FR-3.3 | Map Unifi sites to NetBox sites with configurable mapping | Must |
| FR-3.4 | Sync device names, models, MAC addresses, and IP addresses | Must |
| FR-3.5 | Sync device interfaces and port configurations | Should |
| FR-3.6 | Handle device updates (changed IPs, new firmware versions) on subsequent syncs | Must |
| FR-3.7 | Run sync on a configurable schedule (default: every 6 hours) | Must |
| FR-3.8 | Support Unifi MFA/2FA authentication via OTP seed | Must |
| FR-3.9 | Log sync operations with error reporting | Must |
| FR-3.10 | Support dry-run mode for testing sync before applying | Should |

### FR-4: API & Access

| ID | Requirement | Priority |
|----|------------|----------|
| FR-4.1 | REST API accessible for programmatic access | Must |
| FR-4.2 | GraphQL API enabled | Should |
| FR-4.3 | Web UI accessible via HTTPRoute on private/Tailscale network | Must |
| FR-4.4 | Superuser account provisioned with secure credentials | Must |
| FR-4.5 | API token generated for unifi2netbox sync operations | Must |

## Non-Functional Requirements

### NFR-1: Deployment

| ID | Requirement | Priority |
|----|------------|----------|
| NFR-1.1 | Deploy to Ottawa cluster (talos-ottawa) only | Must |
| NFR-1.2 | Use official netbox-chart Helm chart via Flux HelmRelease | Must |
| NFR-1.3 | Follow existing app pattern: `clusters/talos-ottawa/apps/netbox/` | Must |
| NFR-1.4 | Include namespace.yaml, ks.yaml, kustomization.yaml, and app/ directory | Must |
| NFR-1.5 | Add HelmRepository for netbox chart to `clusters/common/flux/repositories/helm/` | Must |

### NFR-2: Database

| ID | Requirement | Priority |
|----|------------|----------|
| NFR-2.1 | Use CNPG (CloudNativePG) operator for PostgreSQL — not bundled chart PostgreSQL | Must |
| NFR-2.2 | Create dedicated CNPG Cluster resource `netbox-postgres` | Must |
| NFR-2.3 | 3-instance HA configuration (matching existing pattern) | Must |
| NFR-2.4 | Use `ceph-block-replicated-nvme` storage class | Must |
| NFR-2.5 | Configure Barman Cloud S3 backups to Ceph RGW | Must |
| NFR-2.6 | Weekly scheduled backups | Must |
| NFR-2.7 | 30-day backup retention | Must |
| NFR-2.8 | Enable pod monitoring for PostgreSQL metrics | Should |

### NFR-3: Cache / Message Queue

| ID | Requirement | Priority |
|----|------------|----------|
| NFR-3.1 | Use Dragonfly operator for Redis-compatible caching — not bundled chart Redis | Must |
| NFR-3.2 | Create dedicated Dragonfly instance `dragonfly-netbox` | Must |
| NFR-3.3 | Configure separate database numbers for caching and webhooks/tasks | Must |
| NFR-3.4 | Authentication via secret-referenced password | Must |
| NFR-3.5 | 2 replicas with 512MB max memory (matching Fleet pattern) | Should |

### NFR-4: Security

| ID | Requirement | Priority |
|----|------------|----------|
| NFR-4.1 | All secrets encrypted with SOPS using existing cluster keys | Must |
| NFR-4.2 | PostgreSQL credentials via CNPG-generated secrets | Must |
| NFR-4.3 | Dragonfly password stored in SOPS-encrypted secret | Must |
| NFR-4.4 | NetBox superuser password stored in SOPS-encrypted secret | Must |
| NFR-4.5 | NetBox secret key stored in SOPS-encrypted secret | Must |
| NFR-4.6 | Unifi controller credentials stored in SOPS-encrypted secret | Must |
| NFR-4.7 | No public internet exposure (private/Tailscale only) | Must |

### NFR-5: Observability

| ID | Requirement | Priority |
|----|------------|----------|
| NFR-5.1 | PostgreSQL pod monitor enabled for Prometheus scraping | Should |
| NFR-5.2 | NetBox health check endpoint available for Gatus monitoring | Should |
| NFR-5.3 | Unifi sync CronJob logs available in cluster logging | Must |

### NFR-6: Storage

| ID | Requirement | Priority |
|----|------------|----------|
| NFR-6.1 | PostgreSQL storage: 10Gi on ceph-block-replicated-nvme | Must |
| NFR-6.2 | NetBox media storage: PVC for uploaded files (images, attachments) | Should |
