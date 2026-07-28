# auth: route-level access control

tinyauth is the single auth solution for `*.keiretsu.top` web apps (pocket-id has
been fully retired). it does **authN only** through google login and injects
identity headers (`Remote-Email`, `Remote-Groups`). the
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

Add their google email to the `authorization` allow-list of each route they
should reach. Tinyauth accepts valid Google identities; route-level Envoy
authorization is the application access boundary.

Removing a user means removing them from the relevant route allow-lists.

## applications that trust identity headers

Applications such as Grafana can use `Remote-Email` for automatic login. Because
that header is then a credential, the backend must also have destination-side
network policy that permits general access only from the authenticated Envoy
data plane. A ClusterIP Service by itself is not a sufficient trust boundary.

refs: [EG header/method authz](https://gateway.envoyproxy.io/docs/tasks/security/http-header-method-auth/),
[EG ext-auth](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/).
