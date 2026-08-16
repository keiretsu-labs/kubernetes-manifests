# Renovate: Flux OCI HelmRepository dependencies

Research date: 2026-08-16. Sources are Renovate's official documentation,
source, and tests. Renovate 44.30.4 extraction and grouping were also run
against this repository's manifests.

## Conclusion

For an OCI `HelmRepository`, Renovate's `flux` manager emits a `docker`
dependency. The chart name remains `depName`, but `packageName` is the full OCI
path formed from the repository URL and chart name. For this repository the
expected package names are therefore:

```text
ghcr.io/controlplaneio-fluxcd/charts/flux-operator
ghcr.io/controlplaneio-fluxcd/charts/flux-instance
```

`matchPackageNames` matches `packageName`, not `depName`. The grouping rule must
therefore match the full OCI paths (optionally also matching the two chart names
with `matchDepNames`) and give both dependencies the same `groupName`.

`registryAliases` is a source-reference-to-URL fallback, not a way to change an
OCI dependency from `helm` to `docker`. It is needed when the referenced
`HelmRepository` is absent from the scanned files or cannot be linked. For an
OCI alias, the value must be an `oci://` URL; the resulting dependency is still
`docker` with the expanded full package path.

The narrow, documented fallback rule is:

```json
{
  "matchManagers": ["flux"],
  "matchDatasources": ["helm"],
  "registryAliases": {
    "controlplaneio-fluxcd": "oci://ghcr.io/controlplaneio-fluxcd/charts"
  }
}
```

The corresponding matched-pair grouping rule is:

```json
{
  "matchManagers": ["flux"],
  "matchDatasources": ["docker"],
  "matchDepNames": ["flux-operator", "flux-instance"],
  "matchPackageNames": [
    "/^ghcr\\.io\\/controlplaneio-fluxcd\\/charts\\/flux-(operator|instance)$/"
  ],
  "groupName": "flux-operator-instance",
  "minimumGroupSize": 2
}
```

`groupName` puts updates with the same name on one branch/PR. `minimumGroupSize:
2` additionally postpones branch creation until both updates are available;
omit it only if a one-dependency PR is acceptable when the other chart has no
update.

For the current manifests, the alias is a fallback rather than a requirement:
`controlplaneio-fluxcd` is defined as an OCI `HelmRepository` in
`clusters/common/flux/repositories/oci/controlplaneio.yaml`, and both
`HelmRelease` files specify `sourceRef.namespace: flux-system`. The configured
Flux file patterns scan both trees. If those files remain together, the manager
can link the repository directly. The existing working-tree Renovate edits were
left untouched by this research task.

## Primary-source evidence

- [Flux manager documentation](https://docs.renovatebot.com/modules/manager/flux/)
  states that OCI `HelmRepository` sources produce `docker` dependencies; it
  also documents the namespace-linking requirements and the `packageRules`
  form of `registryAliases` for a missing repository.
- Renovate's [`flux/extract.ts`](https://github.com/renovatebot/renovate/blob/main/lib/modules/manager/flux/extract.ts)
  implements `resolveHelmRepository`: OCI repositories switch the datasource
  to Docker and call `getDep(<url-without-oci> + "/" + depName, ...)`; an OCI
  alias follows the same path. Its `extractAllPackageFiles` path collects
  repositories across the scanned files.
- The official [`flux/extract.spec.ts`](https://github.com/renovatebot/renovate/blob/main/lib/modules/manager/flux/extract.spec.ts)
  test `should handle HelmRepository with type OCI` expects
  `datasource: DockerDatasource.id` and a full registry/path/chart
  `packageName`. The tests `uses registryAliases with an OCI URL for
  HelmRelease sourceRef name` and `extracts multiple files` cover alias
  expansion and cross-file repository linking.
- [`matchPackageNames`](https://docs.renovatebot.com/configuration-options/#packagerulesmatchpackagenames)
  explicitly matches the dependency's `packageName` and accepts exact, glob,
  or regular-expression patterns. [`matchDepNames`](https://docs.renovatebot.com/configuration-options/#packagerulesmatchdepnames)
  matches `depName` instead.
- [`groupName`](https://docs.renovatebot.com/configuration-options/#groupname)
  says all updates sharing a name are placed in the same branch/PR;
  [`minimumGroupSize`](https://docs.renovatebot.com/configuration-options/#minimumgroupsize)
  postpones branch creation until the configured number of updates exists. The
  official [`branchify.spec.ts`](https://github.com/renovatebot/renovate/blob/main/lib/workers/repository/updates/branchify.spec.ts)
  test `groups if same compiled group name` verifies that grouping behavior.
- [`registryAliases`](https://docs.renovatebot.com/configuration-options/#registryaliases)
  defines a mergeable object of string aliases and says aliases are applied
  top-to-bottom. The current [`config/options/index.ts`](https://github.com/renovatebot/renovate/blob/main/lib/config/options/index.ts)
  source describes the root option, while the Flux manager README/source/tests
  are the authoritative evidence for its Flux extraction behavior. The source
metadata's `supportedManagers` list currently omits `flux` even though the
Flux manager documentation explicitly documents it; treat that as a
documentation/schema inconsistency and validate the exact Renovate version
used by CI before relying on a newly added alias rule.

## Repository validation

With the repository and OCI source files included, Renovate 44.30.4 extracted
both dependencies as Docker packages with the full paths above and no
`unknown-registry` skip. Supplying the grouping rule to Renovate's local
lookup run produced one `renovate/flux-operator-instance` branch containing
both updates and honored `minimumGroupSize: 2`.
