# auth: route-level access control

tinyauth is a *central* forward-auth: it owns the authorization decision and
keys it on the request host. that's why protecting a new app historically meant
editing `tinyauth/configmap.yaml` (the `TINYAUTH_APPS_<NAME>_*` keys) — the
HTTPRoute and SecurityPolicy only route traffic to tinyauth, they can't carry
the allow-list into it. every new `*.keiretsu.top` app = two more lines in one
configmap that one deployment consumes.

## the pattern: gate on the route, not in the configmap

Envoy Gateway's `authorization` block supports `principal.headers`, and its RBAC
filter runs *after* extAuth. so we can demote tinyauth to **authN only** (log the
user in via google, inject `Remote-Email` / `Remote-Groups`) and put the
**authZ** decision in the per-app SecurityPolicy, right next to its HTTPRoute:

```yaml
extAuth:            # shared, no per-app config — just authenticates
  http:
    backendRefs: [{name: tinyauth, namespace: tinyauth, port: 3000}]
    path: "/api/auth/envoy?path="
    headersToBackend: [remote-user, remote-email, remote-name, remote-groups]
authorization:      # the allow-list, on the route
  defaultAction: Deny
  rules:
    - name: allow-admins
      action: Allow
      principal:
        headers:
          - name: Remote-Groups
            values: ["admins"]
```

adding a protected app becomes: its `httproute.yaml` + `securitypolicy.yaml` in
the app's own folder. the central `tinyauth-config` configmap stays frozen — at
most a coarse global `TINYAUTH_OAUTH_WHITELIST` of who may log in at all.

## status

proven first on `authtest/securitypolicy.yaml`. once the deny path is confirmed
in-cluster, real apps migrate to this shape and the per-app `TINYAUTH_APPS_*`
keys come out of `tinyauth/configmap.yaml`.

refs: [EG header/method authz](https://gateway.envoyproxy.io/docs/tasks/security/http-header-method-auth/),
[EG ext-auth](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/).
