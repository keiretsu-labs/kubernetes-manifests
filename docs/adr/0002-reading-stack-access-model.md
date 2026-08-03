# Access model: Wizarr provisions the ungated readers, one allow-list gates the rest

Users reach this stack over the `public` gateway and are not on the tailnet, so an Envoy extAuth gate is only usable where **no native client exists** — a native client presents an API key or device token, never a tinyauth cookie, and would be denied at the edge. Komga and Audiobookshelf therefore carry **no SecurityPolicy** and are provisioned by **Wizarr** multi-server invites, exactly as Plex and Jellyfin already are; Shelfmark, Omnibus and BookOrbit's browser route share a **single allow-list** and self-register behind it. BookOrbit additionally splits its device endpoints (`/api/v1/{kobo,koreader,opds}/**`) onto a second, ungated HTTPRoute, because a Kobo can carry neither a tailnet membership nor a cookie.

## Consequences

- **Do not add a SecurityPolicy to Komga or Audiobookshelf.** It reads like a missing gate; adding one denies Mihon, Kobo Sync, KOReader and the Audiobookshelf app for every user.
- **Do not merge BookOrbit's two HTTPRoutes**, and do not gate `bookorbit-devices`. Those endpoints authenticate themselves — Kobo via a device token in the path, OPDS via per-user credentials.
- **Self-registration is deliberately asymmetric**: OFF on Komga and Audiobookshelf because they are ungated, ON for the three apps behind the allow-list. Making it uniform either opens the ungated pair to any Google account or breaks hands-off onboarding. If a gate is ever removed, turn that app's self-registration off in the same change.
- **Revocation is credential-based, not allow-list-based.** Removing an address blocks new browser sign-ins but does not stop an already-issued Komga API key or a registered Kobo. Offboarding must revoke credentials in the app.
- Onboarding costs two actions per person — a Wizarr invite and one allow-list line — plus toggling `canRequest` in Omnibus, which hardcodes it to admins only at account creation.
