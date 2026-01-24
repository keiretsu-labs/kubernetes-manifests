# Garage TODOs

## Endpoint Verification

Verify the following endpoints are working correctly:

### Storage Cluster (Direct)
- [ ] `s3.${CLUSTER_DOMAIN}` - Direct S3 API access to storage nodes
- [ ] `garage.${CLUSTER_DOMAIN}` - WebUI access

### Gateway Cluster
- [ ] `s3-gateway.${CLUSTER_DOMAIN}` - S3 API via gateway (scalable API tier)

### Test Commands
```bash
# Test S3 API via storage cluster
curl -I https://s3.killinit.cc/

# Test S3 API via gateway cluster
curl -I https://s3-gateway.killinit.cc/

# Test with AWS CLI (requires configured credentials)
aws --endpoint-url https://s3.killinit.cc s3 ls
aws --endpoint-url https://s3-gateway.killinit.cc s3 ls
```

## Web API Support

Research and implement Garage's Web API (port 3902) for static website hosting:
1. Understand how `[s3_web]` config section works (root_domain, index docs)
2. Determine if operator should expose web API configuration in GarageCluster spec
3. Consider adding HTTPRoute templates for web-hosted buckets
4. Investigate how website hosting interacts with GarageBucket's `website` field
