# A mismatched Omnibus payload is a retryable candidate failure

Indexer labels are not proof of an archive's contents: a release can be labelled for
the requested issue while delivering another series or issue. Omnibus must validate a
downloaded payload before it writes into the library. A confirmed mismatch is a failed
search candidate, not a terminal failure of the request: block that candidate and
immediately search again. It may reject three candidates in total (the original plus
two replacements); only the third rejection leaves the request `STALLED` for review.

The block is durable and scoped to the metadata provider and volume (with the issue
number where known), and records both release title and download link. The current
request keeps the same entries in `failedLinks`, but that alone is insufficient because
the series monitor can create a new request for the still-missing issue. Search merges
the durable blocklist into its exclusions, so monitor-created requests cannot select a
release already proven bad. `rejectedReleaseCount` is independent of the ordinary
download/missing-file `retryCount`; neither failure mode consumes the other's budget.
Each retry receives a unique BullMQ job ID because retained completed jobs otherwise
make a repeated ID look successfully enqueued while silently dropping the search.

The blocklist is visible to an administrator and can be removed deliberately. Manual
or admin retry paths reset the rejected-release budget, which keeps recovery possible
without weakening the automatic three-candidate stop.

## PostgreSQL schema contract

Ottawa supplies Omnibus with a PostgreSQL `DATABASE_URL`, rather than using the
SQLite zero-config default. The image is built with the SQLite Prisma client, so its
entrypoint must first select the datasource from `DATABASE_URL`; for PostgreSQL it
rewrites only the Prisma provider, regenerates the client, and then runs `prisma db
push`. Startup fails if that regeneration fails, rather than running a client whose
dialect disagrees with the database. The Prisma schema must therefore stay in the
SQLite/PostgreSQL-compatible subset and every schema addition used by Ottawa must be
verified against PostgreSQL as well as the default SQLite path.

## Consequences

- A bad archive cannot overwrite a genuine issue under the requested series name, and
  it cannot loop forever through monitor-created request rows.
- One request can make two extra searches before it needs a human decision. An exhausted
  request is intentionally visible as `STALLED`; use interactive search or unblock a
  release when the matcher was too strict.
- The release-blocklist table and `rejectedReleaseCount` column are part of the live
  PostgreSQL contract. Image upgrades depend on the entrypoint completing provider
  selection and `db push` before Omnibus begins processing jobs.
