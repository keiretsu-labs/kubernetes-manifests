# Ottawa Garage bucket migration guard

`bhaiya-postgres` is a production backup bucket. The Garage operator records
its immutable bucket identity in `status.bucketId`. For a new bucket, omit
`spec.bucketId`; for recovery after the Kubernetes object is lost or stuck,
set it to the exact existing remote bucket ID before recreating the object.
The field is immutable once the operator has established the bucket identity.

The bucket and its GarageKey are explicitly excluded from Flux pruning. Keep
that protection in place while moving either resource between Kustomizations
or changing its path. A safe migration is:

1. Apply the destination manifest with the same name and namespace while the
   source inventory still contains the resource. Use the operator's supported
   adoption/recovery procedure to bind a recreated object to the existing
   remote bucket, setting `spec.bucketId` to the verified remote ID.
2. Confirm the destination Kustomization has applied and the bucket/key are
   Ready.
3. Remove the source resource only after the destination inventory owns the
   same Kubernetes object. Never let a path split prune this bucket first.

Do not remove the prune annotations because the bucket is non-empty and
contains production backups. Do not remove the finalizer from a terminating
bucket or delete its objects without explicit recovery approval.
