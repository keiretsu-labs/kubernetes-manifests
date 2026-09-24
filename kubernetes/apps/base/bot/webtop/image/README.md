# webtop-bot image

`ghcr.io/keiretsu-labs/kubernetes-manifests/webtop-bot`

LinuxServer's [webtop](https://docs.linuxserver.io/images/docker-webtop/) plus
the toolchain needed to maintain Go, Python and JS applications and this
GitOps repo, with the AI agents pointed at
[cliproxy](../../../cliproxy/cliproxy/app). Built by
[`.github/workflows/webtop-bot-build.yaml`](../../../../../../.github/workflows/webtop-bot-build.yaml),
deployed by [`../app`](../app).

## Layout

| path | role |
|---|---|
| `Dockerfile` | thin wrapper over the LinuxServer base; no `ENTRYPOINT`/`CMD` |
| `versions.env` | every pinned version, Renovate-managed |
| `install.sh` | build-time provisioner, one stage per Docker layer |
| `root/custom-cont-init.d/` | LinuxServer's boot hook: agent env, home seeding |
| `root/etc/bot/agent-env.sh` | the cliproxy→agent variable mapping, sourced by both consumers |
| `root/etc/profile.d/` | shell setup (login-shell `PATH` repair, agent env) |

## Following the LinuxServer contract

Three rules drive the design, and breaking any of them is the usual way a
derived LinuxServer image goes wrong:

1. **s6-overlay stays PID 1.** The Dockerfile sets no `ENTRYPOINT` or `CMD`,
   so `/init` keeps owning PUID/PGID remapping, the desktop, and Selkies.
2. **`/config` is the user's `~` and it is a volume.** Nothing is written
   there at build time — the mount would mask it. The home layout, the agent
   configs and the `.bashrc` hook are created on every boot by
   `root/custom-cont-init.d/20-bot-home`, which is LinuxServer's documented
   extension point, and ownership is fixed with their own `lsiown` wrapper
   rather than a hardcoded uid.
3. **One desktop, one user.** `PUID=0`/`PGID=0` in the Deployment makes
   LinuxServer's `abc` account uid 0, so the session is root and `sudo`, `apt`
   and the toolchains all work without a second identity. A second user means
   a second webtop, not a second account.

No single mechanism reaches every caller, so the agent environment is applied
twice from one mapping in `root/etc/bot/agent-env.sh`:

- `custom-cont-init.d/10-bot-environment` writes it into
  `/run/s6/container_environment`, which is the s6 way to reach every service
  started afterwards — the desktop session and anything launched from a GUI
  menu. A `/etc/profile.d` script alone would miss those, since a menu entry
  is not a login shell.
- `/etc/profile.d/90-bot-tooling.sh` exports it for shells, because
  `kubectl exec` starts from the container's original environment and never
  sees `/run/s6/container_environment`.

`PATH` is likewise set in two places. The Dockerfile `ENV` *prepends* to the
base's `PATH` (which carries `/lsiopy/bin`, the LinuxServer venv Selkies runs
from — replacing it wholesale breaks the desktop), and `profile.d` re-adds the
toolchain dirs because Debian's `/etc/profile` rewrites `PATH` from scratch for
login shells.

## Swapping the desktop flavour

The base image is a build ARG and `install.sh` resolves the package manager at
build time (`apt-get`/`apk`/`pacman`/`dnf`), so any webtop variant works:

```bash
gh workflow run webtop-bot-build.yaml -f flavor=debian-kde
```

That publishes `webtop-bot:debian-kde`. Point `image:` in
`../app/deployment.yaml` at the new tag and commit. To change the default,
edit `WEBTOP_BASE_TAG` in `versions.env`.

Every build also publishes an immutable `<flavor>-<sha>` tag to roll back to.

## What is baked in

- **Go** toolchain, `golangci-lint`
- **Node** LTS with `corepack` (pnpm, yarn)
- **Python** via `uv`/`uvx` — `uv` also manages the interpreters, so there is
  no separate Python pin
- **Agents** — Hermes Agent, `herdr`, `codex`, `claude`
- **GitOps** — `kubectl`, `helm`, `flux`, `kustomize`, `talosctl`, `sops`,
  `age`, `gh`, `yq`
- **Shell** — `git`, `jq`, `ripgrep`, `fd`, `fzf`, `tmux`, `shellcheck`,
  `build-essential`, dig/ping/nc

Per-user caches (`GOPATH`, npm prefix and cache, `UV_CACHE_DIR`) are pushed
onto the home volume by `root/etc/profile.d/90-bot-tooling.sh`, so
`npm i -g` and `go install` work in-session without touching image layers.

## cliproxy wiring

The Deployment supplies exactly two values, `CLIPROXY_BASE_URL` and
`CLIPROXY_API_KEY`. Knowing that each CLI wants a different shape is the
image's job:

| CLI / SDK | how it is pointed at cliproxy |
|---|---|
| `codex` | `~/.codex/config.toml` provider `cliproxy`, `wire_api = "responses"` against `/v1`, key read from the env via `env_key` |
| `hermes` | `~/.hermes/config.yaml` seeds the OpenAI provider and `CLIPROXY_HERMES_MODEL`; endpoint and key come from `OPENAI_BASE_URL` + `OPENAI_API_KEY` |
| `claude` | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` (`/v1/messages`) |
| OpenAI SDKs | `OPENAI_BASE_URL` + `OPENAI_API_KEY` (`/v1`) |
| Gemini SDKs | `GOOGLE_GEMINI_BASE_URL` + `GEMINI_API_KEY` (`/v1beta`) |
| `herdr` | nothing — it multiplexes the agents above rather than calling a model itself |

Hermes code and its virtual environment are baked into the image at the pinned
`HERMES_VERSION`. Its mutable state and lazy-installed optional packages use
`/config/.hermes`; this deployment's `/config` is an `emptyDir`, so Hermes
state lasts for the pod lifetime and resets when the pod is replaced.

The key is never written to a file: `codex` reads it from the environment at
call time, and the others take it as an env var.

Because it arrives as a `secretKeyRef` env var, rotating `CLIPROXY_API_KEY` in
ottawa cluster-secrets needs a `kubectl rollout restart deploy/webtop -n bot`
to take effect — Flux updates the Secret but the Deployment spec is unchanged,
so nothing rolls on its own. The alternative, putting the substituted value in
a pod annotation to force a roll (as `gatus` does), would expose it in
`kubectl get pod -o yaml`, which is not worth it for a one-line restart.

cliproxy runs with `force-model-prefix: true`, so model names carry their
route prefix. The codex default is `CLIPROXY_CODEX_MODEL` in the Deployment,
and the prefix matters more than it looks:

- `codex-subscription/*` is Codex's own backend, so cliproxy passes
  `/v1/responses` straight through. This is what `codex` wants.
- `ai/*` and `ai-kartik/*` are openai-compatible providers that cliproxy
  reaches over `chat/completions`. Fine for most models, but the `gpt-*-codex`
  ones there reject that endpoint — `ai/gpt-5.3-codex` appears in
  `GET /v1/models` and still 400s for this CLI.

So presence in the catalog is not proof a model works for a given client;
check the route too. The catalog lives in
[`providers.yaml`](../../../cliproxy/cliproxy/app/providers/providers.yaml).
