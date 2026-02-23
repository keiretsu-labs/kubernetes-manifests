# Rajsingh macOS VM

A macOS VM running in Kubernetes for development and testing.

## Access

- **VNC**: Connect via the Tailscale IP (raj-mac.keiretsu.ts.net)
- **HTTP**: http://raj-mac.keiretsu.ts.net (port 8006)

## Backup to Garage S3

### Prerequisites

The VM has access to the Garage S3 bucket. Use the same credentials as other apps:

```bash
# Get credentials from cluster secret
AWS_ACCESS_KEY_ID=$(kubectl get secret garage-benchmark-s3-credentials -n garage-benchmark -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
AWS_SECRET_ACCESS_KEY=$(kubectl get secret garage-benchmark-s3-credentials -n garage-benchmark -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=garage
export AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
```

### Backup Commands

#### Full Disk Image (recommended)

```bash
# Create a compressed disk image of /Users
dd if=/dev/sda | gzip | aws s3 cp - s3://rajsingh/macos-backup-$(date +%Y%m%d).img.gz \
  --endpoint-url http://garage.garage:3900 \
  --no-verify-ssl

# Or using rclone (if installed)
rclone copy /Users remote:rajsingh/macos-backup-$(date +%Y%m%d) \
  --s3-endpoint http://garage.garage:3900 \
  --s3-no-check-certificate
```

#### Using rsync (for incremental backups)

```bash
# Install rsync if needed
brew install rsync

# Sync specific directories
rsync -avz --progress /Users/Documents remote:rajsingh/documents-backup/ \
  --s3-endpoint http://garage.garage:3900 \
  --s3-no-check-certificate

rsync -avz --progress /Users/Pictures remote:rajsingh/pictures-backup/ \
  --s3-endpoint http://garage.garage:3900 \
  --s3-no-check-certificate
```

### Restore from Backup

```bash
# Download and restore disk image
aws s3 cp s3://rajsingh/macos-backup-20240101.img.gz - | gunzip | dd of=/dev/sda \
  --endpoint-url http://garage.garage:3900 \
  --no-verify-ssl

# Or restore specific files
aws s3 sync s3://rajsingh/documents-backup/ /Users/Documents/ \
  --endpoint-url http://garage.garage:3900 \
  --no-verify-ssl
```

### Automated Backups (cron)

Add to crontab on the macOS VM:

```bash
# Edit crontab
crontab -e

# Add daily backup at 2am
0 2 * * * /usr/bin/rsync -avz --delete /Users/Documents s3://rajsingh/documents-backup-$(hostname)/ --s3-endpoint http://garage.garage:3900 --s3-no-check-certificate >> /var/log/backup.log 2>&1
```

## Storage

- PVC: 64Gi (macos-pvc)
- Storage backend: Rook-Ceph on Robbinsdale

## Troubleshooting

- **KVM not available**: Ensure the node has `/dev/kvm` exposed
- **Slow performance**: Increase RAM_SIZE or CPU_CORES in deployment
- **Backup fails**: Check network connectivity to Garage S3 endpoint
