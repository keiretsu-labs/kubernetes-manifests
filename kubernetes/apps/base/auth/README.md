# auth: route-level access control

tinyauth is the single auth solution for `*.keiretsu.top` web apps (pocket-id has
been fully retired). it does **authN only** — google login, gated by a global
whitelist — and injects identity headers (`Remote-Email`, `Remote-Groups`). the
**authZ** decision (who may reach a given app) lives on each route's
SecurityPolicy, because Envoy Gateway's `authorization` block matches on
`principal.headers` and its RBAC filter runs *after* extAuth, so it sees the
header tinyauth injected.

## the pattern

a protected route = an HTTPRoute + a SecurityPolicy with two blocks:

```yaml
extAuth:            # shared, no per-app config — just authenticates via tinyauth
  headersToExtAuth: [cookie, x-forwarded-proto, x-forwarded-for, user-agent]
  http:
    backendRefs: [{name: tinyauth, namespace: tinyauth, port: 3000}]
    path: "/api/auth/envoy?path="
    headersToBackend: [remote-user, remote-email, remote-name, remote-groups]
authorization:      # the allow-list, on the route
  defaultAction: Deny
  rules:
    - name: allow
      action: Allow
      principal:
        headers:
          - name: Remote-Email
            values: ["someone@gmail.com"]
```

cross-namespace extAuth to the tinyauth Service is allowed by the ReferenceGrant
in `tinyauth/referencegrant.yaml` — add a new app namespace to its `from` list.

live examples: `agents/agents/app/hermes-auth-securitypolicy.yaml` (per-user
dashboards) and `teaspoon/securitypolicy.yaml`.

## onboarding a new user

1. add their google email to `TINYAUTH_OAUTH_WHITELIST` in `tinyauth/tinyauth.env`
   (the authN gate — who may log in at all). the configMapGenerator hash rolls
   tinyauth automatically on merge.
2. add the same email to the `authorization` allow-list of each route they should
   reach. that's the only per-app edit; no central ACL.

removing a user is the reverse: drop them from the whitelist and any route lists.

## two layers, on purpose

- `TINYAUTH_OAUTH_WHITELIST` — coarse authN gate + fail-safe (a route that ships
  without an `authorization` block is still capped to known users).
- per-route `authorization` — the real per-app allow-list.

refs: [EG header/method authz](https://gateway.envoyproxy.io/docs/tasks/security/http-header-method-auth/),
[EG ext-auth](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/).
