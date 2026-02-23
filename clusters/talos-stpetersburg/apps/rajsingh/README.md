# Rajsingh macOS VM

A macOS VM running in Kubernetes for development and testing.

## Access

- **VNC**: Connect via the Tailscale IP (raj-mac.keiretsu.ts.net)
- **HTTP**: http://raj-mac.keiretsu.ts.net (port 8006)

## VolSync Backup to Garage S3

The macOS PVC is backed up to Garage S3 using VolSync with Restic.

### Current Configuration

The backup uses:
- **Schedule**: Daily at 2:00 AM (0 2 * * *)
- **Retention**: Daily: 3, Weekly: 4, Monthly: 2, Yearly: 1
- **Storage**: Garage S3 (keiretsu bucket)

### Add VolSync Backup

To enable VolSync backup for the macOS PVC:

```bash
# Create the volsync-backup.yaml in the app directory
cat > volsync-backup.yaml << 'EOF'
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: raj-macos
spec:
  sourcePVC: macos-pvc
  trigger:
    schedule: "0 2 * * *"  # Daily at 2am
  restic:
    pruneIntervalDays: 14
    repository: restic-rajsingh-macos
    retain:
      hourly: 1
      daily: 3
      weekly: 4
      monthly: 2
      yearly: 1
    copyMethod: Direct
    storageClassName: ceph-block-replicated-nvme
---
apiVersion: v1
kind: Secret
metadata:
  name: restic-rajsingh-macos
type: Opaque
stringData:
  RESTIC_REPOSITORY: s3:http://garage.garage:3900/keiretsu/ottawa/rajsingh/macos
  RESTIC_PASSWORD: <your-restic-password>
  AWS_ACCESS_KEY_ID: <your-s3-access-key>
  AWS_SECRET_ACCESS_KEY: <your-s3-secret-key>
EOF
```

### Get S3 Credentials

```bash
# Get Garage S3 credentials from an existing secret
kubectl get secret garaged-s3-credentials -n garage -o jsonpath='{.data}'
```

### Check Backup Status

```bash
# Check replication source status
kubectl get replicationsource raj-macos -n rajsingh -o yaml

# List restic snapshots
kubectl exec -n rajsingh deploy/macos -- /bin/sh -c '
  apt-get update && apt-get install -y restic 2>/dev/null
  export RESTIC_REPOSITORY=s3:http://garage.garage:3900/keiretsu/ottawa/rajsingh/macos
  export RESTIC_PASSWORD=<your-password>
  restic snapshots
'
```

### Restore from Backup

```bash
# Create a restore CR
cat > volsync-restore.yaml << 'EOF'
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: raj-macos-restore
spec:
  trigger:
    manual: restore-once
  restic:
    repository: restic-rajsingh-macos
    destinationPVC: macos-pvc-restore
    storageClassName: ceph-block-replicated-nvme
    capacity: 64Gi
EOF

kubectl apply -f volsync-restore.yaml -n rajsingh

# Check restore status
kubectl get replicationdestination raj-macos-restore -n rajsingh -o yaml
```

## Manual Backup (alternative)

If VolSync is not configured, you can manually backup using rclone or aws-cli from within the VM:

```bash
# Using rclone
rclone copy /Users s3:rajsingh/macos-backup \
  --s3-endpoint http://garage.garage:3900 \
  --s3-no-check-certificate
```

## Storage

- PVC: 64Gi (macos-pvc)
- Storage backend: Rook-Ceph on Robbinsdale

## Troubleshooting

- **KVM not available**: Ensure the node has `/dev/kvm` exposed
- **Slow performance**: Increase RAM_SIZE or CPU_CORES in deployment
- **Backup fails**: Check VolSync and Restic pod logs
