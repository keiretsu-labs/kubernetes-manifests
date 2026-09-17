# Nix binary cache

The shared Garage bucket is `nix-cache`, with a 500 GiB quota and a seven-day
abort rule for incomplete multipart uploads. It is separate from the `zot`
bucket.

- Writer: Woodpecker CI uses `nix-cache-writer-key`, whose generated Kubernetes
  Secret is `woodpecker/nix-cache-writer-s3`. The CI copy of its credentials is
  kept in the Woodpecker secret store, not in Git or a Kubernetes manifest.
- Reader: builders use `nix-cache-reader-key`, whose generated Kubernetes Secret
  is `woodpecker/nix-cache-reader-s3`. It has read-only bucket permission.
- Endpoint: `http://garage-gateway.garage.svc.cluster.local:3900`.

The GarageBucket CRD has no anonymous-read field for `garage bucket allow
--read`; its `website` setting is static website hosting, not bucket access.
This rollout therefore uses a dedicated read-only key instead of inventing a
public-read CR field. A future public HTTP substituter must preserve the
read-only boundary and be reviewed separately.

The signing key is `nix-cache-ottawa-1`. Add its public key to every consumer's
`trusted-public-keys` before rotating the signer. During rotation, publish the
new public key first, wait for consumers to converge, then change the
Woodpecker signing secret; retain the old public key until old cache entries no
longer need verification.

Retention/pruning is intentionally a placeholder. The multipart-abort rule is
safe housekeeping; object expiry must be designed and reviewed against release
reproducibility before enabling it.
