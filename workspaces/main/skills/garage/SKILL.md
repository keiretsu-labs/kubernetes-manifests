---
name: Garage Operations
description: >
  S3-compatible object storage operations for self-hosted Garage clusters.

  Use when: Checking Garage cluster health, managing buckets, troubleshooting
  S3 connectivity, viewing storage stats, key management, or operator issues.

  Don't use when: The issue is block storage (Ceph) or file storage (NFS) — use
  storage-ops. Don't use for general cluster health (use cluster-health). Don't
  use for image registry issues (use zot-registry).

  Outputs: Garage cluster status, bucket inventory, storage usage, S3 gateway
  connectivity tests, and operator health diagnostics.
requires: []
---

# Garage Operations

## Routing

### Use This Skill When
- Checking Garage cluster status and health
- Viewing storage capacity and usage
- Listing or creating buckets
- Managing S3 keys
- Troubleshooting S3 connectivity
- Garage operator is not reconciling
- Multi-cluster replication issues

### Don't Use This Skill When
- Block storage issues (Ceph PVCs) → use **storage-ops**
- Image registry issues → use **zot-registry**
- General cluster health → use **cluster-health**
- Flux reconciliation → use **flux-ops**

## Architecture Overview

Your Garage setup runs as a multi-cluster S3-compatible object store:

| Cluster | Namespace | Garage Pod | WebUI | S3 Endpoint |
|---------|-----------|------------|-------|--------------|
| Ottawa | `garage` | `garage-0` | `garage-webui-*` | `ottawa-garage.keiretsu.ts.net:3903` |
| Robbinsdale | `garage` | `garage-0` | `garage-webui-*` | `robbinsdale-garage.keiretsu.ts.net:3903` |
| StPetersburg | `garage` | `garage-0` | `garage-webui-*` | `stpetersburg-garage.keiretsu.ts.net:3903` |

There's also a Tailscale-hosted Garage in the `tailscale` namespace:
- `ts-ottawa-garage-c4vws-0`
- `ts-robbinsdale-garage-wtkkr-0`
- `ts-stpetersburg-garage-wxfgl-0`

### CRDs
- `GarageCluster` — defines the cluster configuration
- `GarageBucket` — defines buckets and quotas
- `GarageKey` — S3 access keys
- `GarageAdminToken` — admin credentials
- `GarageNode` — node membership (informational)

## Quick Status Check

### All Clusters
```bash
kubectl get garageclusters -A
kubectl get garagebuckets -A
kubectl get garagenodes -A
```

### Per-Cluster Status
```bash
# Replace <cluster> with ottawa, robbinsdale, or stpetersburg
kubectl --context <cluster> get garageclusters -n garage
kubectl --context <cluster> get pods -n garage
kubectl --context <cluster> get events -n garage --sort-by='.lastTimestamp' | tail -10
```

### Operator Health
```bash
kubectl get pods -n garage-operator-system
kubectl logs -n garage-operator-system -l app=garage-operator --tail=30
```

## Cluster Health

### Garage Status
The garage CLI isn't available in the pod. Use CRDs for status:
```bash
kubectl get garagenodes -A
kubectl get garageclusters -A -o wide
```

### Node Status
```bash
kubectl get garagenodes -A -o wide
kubectl get garagenodes -n garage -o jsonpath='{.items[*].status}'
```

### Disk Usage
```bash
# Check PVC capacity
kubectl get pvc -n garage

# Check data directory size on the node (requires node access)
kubectl exec -n garage garage-0 -- df -h /data
```

## Bucket Operations

### List Buckets
```bash
kubectl get garagebuckets -A
```

### Bucket Details
```bash
kubectl get garagebucket <name> -n garage -o yaml
```

### Create a Bucket (via CR)
```yaml
# Save as garage-bucket.yaml
apiVersion: garage.rajsingh.info/v1alpha1
kind: GarageBucket
metadata:
  name: my-bucket
spec:
  clusterRef:
    name: garage
  globalAlias: my-bucket
  quotas:
    maxSize: 100Gi
    maxObjects: 1000000
  keyPermissions:
    - keyRef: <key-name>
      read: true
      write: true
```

### Delete a Bucket
```bash
kubectl delete garagebucket <name> -n garage
```

## Key Management

### List Keys
```bash
kubectl get garagekeys -A
```

### Create a Key (via CR)
```yaml
# Save as garage-key.yaml
apiVersion: garage.rajsingh.info/v1alpha1
kind: GarageKey
metadata:
  name: my-app-key
spec:
  clusterRef:
    name: garage
  secretRef:
    name: my-app-key-secret
    # secret is created automatically by the operator
```

### Get Key Secret
```bash
kubectl get secret <key-name> -n garage -o jsonpath='{.data.access_key}' | base64 -d
kubectl get secret <key-name> -n garage -o jsonpath='{.data.secret_key}' | base64 -d
```

## S3 Connectivity

The S3 gateway is exposed via the `garage-ts` service (port 3903 for HTTP).

```bash
# Test S3 access (HTTP 400 means endpoint is responding)
curl -I http://ottawa-garage.keiretsu.ts.net:3903/
curl -I http://robbinsdale-garage.keiretsu.ts.net:3903/
curl -I http://stpetersburg-garage.keiretsu.ts.net:3903/

# List buckets with aws CLI
aws --endpoint http://ottawa-garage.keiretsu.ts.net:3903 s3 ls
```

### S3 Gateway Status
```bash
kubectl get svc -n garage
# S3 typically on port 3903 (HTTP)
```

### Common S3 Issues
| Symptom | Likely Cause | Fix |
|---------|---------------|-----|
| 403 Forbidden | Wrong access key or secret | Verify key exists and permissions |
| 404 Not Found | Bucket doesn't exist | Check `kubectl get garagebuckets -A` |
| Connection timeout | Network/Firewall | Check Tailscale connection, verify S3 endpoint |
| 501 Not Implemented | Unsupported S3 operation | Garage has limited S3 coverage |

## Operator Troubleshooting

### Check Operator Logs
```bash
kubectl logs -n garage-operator-system -l app=garage-operator --tail=50
```

### Reconcile a Cluster
```bash
kubectl annotate garagecluster garage -n garage \
  reconcile.rajsingh.info/force='true' --overwrite
```

### Operator Pod Issues
```bash
kubectl describe pod -n garage-operator-system -l app=garage-operator
kubectl get events -n garage-operator-system --field-selector type=Warning
```

## WebUI

The WebUI is available via the `garage-webui` service:

```bash
# Cluster-local access
kubectl port-forward -n garage svc/garage-webui 8080:80

# Then open http://localhost:8080
```

Or via Tailscale (if exposed):
- `http://ottawa-garage.keiretsu.ts.net:3903/` (may need path from webui route)

Use the admin token from the `garage-admin-token` secret:
```bash
kubectl get secret garage-admin-token -n garage -o jsonpath='{.data.admin-token}' | base64 -d
```

## Multi-Cluster

Your setup defines remote cluster connections in the GarageCluster CR:
```bash
kubectl get garagecluster garage -n garage -o yaml | grep -A20 remoteClusters
```

Check cluster connectivity:
```bash
# Test from each cluster context
for ctx in ottawa robbinsdale stpetersburg; do
  echo "=== $ctx ==="
  kubectl --context=$ctx get garagenodes -n garage
done
```

## Common Issues

| Symptom | Likely Cause | Action |
|---------|---------------|--------|
| Garage pod not starting | PVC issue or resource limits | Check `kubectl describe pod garage-0 -n garage` |
| Operator CrashLoopBackOff | CRD issue or RBAC | Check operator logs |
| Bucket not created | Operator not watching namespace | Check garageclusters status |
| Slow S3 ops | Network between zones | Test latency between clusters |
| Disk space full | Data pool too small | Check PVC size, may need expansion |

## Artifact Handoff

For complex Garage investigations:
- `mkdir -p /tmp/outputs` before writing any artifacts
- Write findings to `/tmp/outputs/garage-diagnosis.md` including cluster status, bucket list, and operator logs.
