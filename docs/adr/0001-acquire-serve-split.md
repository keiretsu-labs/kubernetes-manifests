# Acquirers do not serve; library servers do not acquire

Comics, graphic novels, and manga are served exclusively by Komga, even though Omnibus and Suwayomi — the services that acquire them — both ship capable web readers, and BookOrbit can read CBZ/CBR/CB7 as well. Komga owns user accounts and per-user read progress for all picture content because it has the deepest open-source client ecosystem (Mihon, Komelia, KMReader, MangaBox) plus native Kobo Sync and KOReader Sync, and because Suwayomi is single-user by design and so can never serve anyone but the admin. Each library tree therefore has exactly one writer — Omnibus writes `omnibus-comics`, Suwayomi writes `suwayomi-manga` — with Komga mounting both read-only, while BookOrbit is scoped to ebooks, where its external metadata providers are what earn it a place.

## Consequences

- Reader choice is effectively load-bearing: user accounts, read progress, and Kobo/KOReader sync state live in the serving app's database, so moving picture content to a different server later loses everyone's reading position.
- Metadata must be embedded by the acquirer, not the server. Omnibus writes `ComicInfo.xml` and Mylar-format `series.json`; Suwayomi writes `ComicInfo.xml`. Komga reads both, so no metadata-fetching sidecar (Komf) is needed.
- BookOrbit's ComicVine provider and its comics reader go deliberately unused. Don't wire them up "for completeness" — that would create a second writer on a library tree.
