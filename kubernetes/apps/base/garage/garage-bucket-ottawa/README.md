# Ottawa Garage bucket migration guard

`bhaiya-postgres` is a production backup bucket. Its `spec.bucketId` is the
Garage-internal identity of the existing bucket and must remain unchanged.

The bucket and its GarageKey are explicitly excluded from Flux pruning. Keep
that protection in place while moving either resource between Kustomizations
or changing its path. A safe migration is:

1. Apply the destination manifest with the same name, namespace, and
   `spec.bucketId` while the source inventory still contains the resource.
2. Confirm the destination Kustomization has applied and the bucket/key are
   Ready.
3. Remove the source resource only after the destination inventory owns the
   same Kubernetes object. Never let a path split prune this bucket first.

Do not remove the prune annotations or the `bucketId` because the bucket is
non-empty and contains production backups. The Garage operator's
`spec.bucketId` recovery path adopts the existing remote bucket without
creating a replacement.
