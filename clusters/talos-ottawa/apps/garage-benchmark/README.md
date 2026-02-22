# Garage Benchmark

A dedicated S3 benchmark pod for testing Garage performance.

## Deploy

Uncomment the ks.yaml and push:

```bash
git checkout main
# Edit ks.yaml to uncomment
git add -A
git commit -m "enable(garage-benchmark): enable benchmark app"
git push
flux reconcile kustomization cluster-apps -n flux-system --with-source
```

## Run Benchmark

### From inside the cluster

```bash
# Exec into the benchmark pod
kubectl exec -n garage-benchmark benchmark -it -- /bin/sh

# Set credentials
export AWS_ACCESS_KEY_ID="GK1902dac35c3dd5a0cdc2d1e4"
export AWS_SECRET_ACCESS_KEY="f299b08ae91464ac7a1d98e771124ce33f22259f19b4f08c34fa9776c19f8f9b"
export AWS_DEFAULT_REGION="garage"

# List buckets
aws s3 ls --endpoint-url http://garage.garage:3900 --no-verify-ssl

# Create test bucket
aws s3 mb s3://benchmark --endpoint-url http://garage.garage:3900 --no-verify-ssl

# Upload test (100MB)
dd if=/dev/zero of=/tmp/testfile bs=1M count=100
time aws s3 cp /tmp/testfile s3://benchmark/testfile --endpoint-url http://garage.garage:3900 --no-verify-ssl

# Download test (100MB)
time aws s3 cp s3://benchmark/testfile /tmp/downloaded --endpoint-url http://garage.garage:3900 --no-verify-ssl

# Cleanup
aws s3 rm s3://benchmark/testfile --endpoint-url http://garage.garage:3900 --no-verify-ssl
aws s3 rb s3://benchmark --endpoint-url http://garage.garage:3900 --no-verify-ssl
```

### Quick benchmark script

```bash
kubectl exec -n garage-benchmark benchmark -- /bin/sh -c '
export AWS_ACCESS_KEY_ID="GK1902dac35c3dd5a0cdc2d1e4"
export AWS_SECRET_ACCESS_KEY="f299b08ae91464ac7a1d98e771124ce33f22259f19b4f08c34fa9776c19f8f9b"
export AWS_DEFAULT_REGION="garage"

# 100MB test
dd if=/dev/zero of=/tmp/testfile bs=1M count=100
echo "=== Upload 100MB ==="
time aws s3 cp /tmp/testfile s3://benchmark/testfile --endpoint-url http://garage.garage:3900 --no-verify-ssl

echo "=== Download 100MB ==="
time aws s3 cp s3://benchmark/testfile /tmp/downloaded --endpoint-url http://garage.garage:3900 --no-verify-ssl

# Cleanup
aws s3 rm s3://benchmark/testfile --endpoint-url http://garage.garage:3900 --no-verify-ssl
'
```

## Results Interpretation

- **4K Blu-ray streaming**: Requires 50-100 Mbps (6.25-12.5 MB/s)
- **1080p streaming**: Requires 5-10 Mbps

## Disable

Comment out ks.yaml and push to deschedule.
