# Environment Variables

All configuration is driven by a single `.env` file in the repository root. Copy the template:

```bash
cp example.env .env
```

Below is the complete reference.

## Runtime UID/GID

Used by `templates/docker/compose.uid-gid.yml` and the custom bench entrypoint.

| Variable | Default | Description |
|----------|---------|-------------|
| `USERID` | `1000` | UID to assign to the `frappe` user at container start. Set to your host user's UID (`id -u`) so bind-mounted files are writable. |
| `GROUPID` | `1000` | GID to assign to the `frappe` user. If different from `USERID`, a new group `frappegid` is created. |

If both values match the image defaults (1000:1000), the entrypoint skips remapping entirely — no performance overhead.

## Upstream bench image

Used by `non.prod.compose.yml` (every stack) and `templates/docker/compose.uid-gid.yml`.

The `frappe/bench` image is what ships the `bench` CLI, the pyenv Pythons and the nvm Node. Choosing its tag is how you choose the bench version. Upstream publishes `latest` and one tag per bench release, rebuilt nightly.

| Variable | Default | Description |
|----------|---------|-------------|
| `BENCH_IMAGE` | `frappe/bench` | Upstream image name. |
| `BENCH_TAG` | `latest` | Upstream image tag. **Same meaning in every stack:** without the uid-gid override the containers run this image as-is; with it, it is the `FROM` of the locally built wrapper, which is always named `bench:${BENCH_TAG}` (not configurable) so the local tag tells you which upstream tag it came from. |
| `PULL_POLICY` | `never` | Compose pull policy for the image the containers run. `never` only uses images already on the host: stacks that run the upstream image directly (no uid-gid override) need a manual `docker pull frappe/bench:<tag>` before the first `up` and after every `BENCH_TAG` change, or set `missing` to pull only when absent. Stacks with the uid-gid override are unaffected, since `docker compose build` fetches a missing base image itself. |

Build the wrapper image with Compose, which reads these variables from the rendered file, instead of a manual `docker build`:

```bash
docker compose -f devops/docker/dev.docker-compose.yml build
```

## Frappe branch

Used by the `configurator` and `frappe` services in `non.prod.compose.yml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `FRAPPE_BRANCH` | `version-16` | Git ref of `frappe/frappe`, passed verbatim to `bench init --frappe-branch`, and the suffix of the bench directory (`frappe-bench-<ref>` under `/workspace/development`, e.g. `frappe-bench-version-16`). A **branch** (`version-16`, `version-15`, `develop`) installs the latest release of that line at init time and the checkout tracks upstream, so `bench update` works later. A **tag** (`v15.x.x`, `v16.x.x`) pins one release as a detached HEAD, which is what you want for pre-production. The directory name is what makes the init idempotent, so changing the value creates a new bench next to the old one on the next start. Exposed inside the `frappe` container too, so `cd frappe-bench-$FRAPPE_BRANCH` works. |

Each ref declares its own interpreter requirements (`requires-python` in `pyproject.toml`, `engines.node` in `package.json`). The image's default Python and Node satisfy the current `version-16` and `version-15` branches; for another ref, compare its requirements with what the image ships (`pyenv versions` and `node --version` inside the container) and pin `BENCH_PYTHON_VERSION` if needed.

## Bench Python version

Used by the `configurator` service in `non.prod.compose.yml` when it runs `bench init` on first start.

| Variable | Default | Description |
|----------|---------|-------------|
| `BENCH_PYTHON_VERSION` | `auto` | pyenv version (a major.minor prefix is fine) used to create the bench virtualenv. `auto` (or empty) leaves `PYENV_VERSION` unset, so `bench init` uses the image's default `python3`. Set an explicit version only for refs that need another interpreter; it must be one the image ships (`pyenv versions` inside the container). |

## Bench dev ports

Ports the bench dev server (`bench start`) binds **inside** the container. These variables are shared by **both** the local-ports override and the Traefik/SSL override so the two stacks never drift.

Used by `templates/docker/compose.local-ports.yml` and `templates/docker/compose.non-prod-https.yaml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `FRAPPE_WEB_PORT` | `8000` | Web / werkzeug port. Low bound of the locally-published web range **and** the single port Traefik forwards to. |
| `FRAPPE_SOCKETIO_PORT` | `9000` | Socketio (realtime) port. Low bound of the locally-published socketio range **and** the port Traefik forwards to. |
| `FRAPPE_WEB_PORT_LAST` | `8005` | High bound of the locally-published web range (local-ports only). |
| `FRAPPE_SOCKETIO_PORT_LAST` | `9005` | High bound of the locally-published socketio range (local-ports only). |

`bench init` → `make_ports()` scans sibling benches in `/workspace/development` and assigns `max(existing)+1`, so a second bench lands on `8001/9001`, a third on `8002/9002`, and so on.

- **Local:** the override publishes a **range** (`FRAPPE_WEB_PORT`..`FRAPPE_WEB_PORT_LAST`), so any bench in that range is reachable on the host with no reconfig.
- **SSL:** these variables are NOT read by the compose override. Instead, they're documented here for reference to the local-ports scenario. For the SSL/Traefik scenario, hostnames and ports are configured directly in `devops/traefik/*.yml` files — see [Traefik / HTTPS](traefik-ssl.md).

## Local host ports

Used by `templates/docker/compose.local-ports.yml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST_BIND` | `127.0.0.1` | Network interface the bench ports bind to. Use `0.0.0.0` to expose to the LAN. |

Only the bind address changes here; the published range itself is controlled by the `FRAPPE_*_PORT` variables above.

## HTTPS / Traefik

Used by `templates/docker/compose.non-prod-https.yaml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `HTTP_PUBLISH_PORT` | `80` | Host port for Traefik's HTTP entrypoint. |
| `HTTPS_PUBLISH_PORT` | `443` | Host port for Traefik's HTTPS entrypoint. |

**Note:** `letsencrypt_email`, `caServer`, entrypoints, and ACME settings are configured in `devops/traefik-static.yml` (plain YAML, no templating) — see [Traefik / HTTPS](traefik-ssl.md). Hostnames and bench ports are configured in `devops/traefik/bench-XX.yml`.

## Database and cache

These are not set in `.env` by default but are referenced in `non.prod.compose.yml` and passed through to the configurator. They are set automatically by the MariaDB and Redis Compose overrides via Docker networking:

| Variable | Used by | Description |
|----------|---------|-------------|
| `DB_HOST` | `non.prod.compose.yml` (configurator) | Hostname of the MariaDB service. |
| `DB_PORT` | `non.prod.compose.yml` (configurator) | Port of the MariaDB service. |
| `REDIS_CACHE` | `non.prod.compose.yml` (configurator) | Redis connection string for caching. |
| `REDIS_QUEUE` | `non.prod.compose.yml` (configurator) | Redis connection string for background job queues. |
| `DB_PASSWORD` | `frappe_docker/overrides/compose.mariadb.yaml` (db) | MariaDB root password, default `123`. Pass it to `bench new-site --db-root-password`. |

These are typically resolved by Docker Compose service discovery (e.g. `db:3306`, `redis-cache:6379`) and do not need to be set manually unless you are connecting to external services.

## Example `.env` file

```env
# UID/GID — match your host user
USERID=1001
GROUPID=1001

# Upstream bench image (bench CLI + toolchain); same meaning in every stack
BENCH_IMAGE=frappe/bench
BENCH_TAG=latest
PULL_POLICY=never

# Frappe git ref (branch or tag) — bench dir frappe-bench-<ref>
FRAPPE_BRANCH=version-16

# Python for `bench init` — `auto` = image default; pin only if the ref needs another interpreter
BENCH_PYTHON_VERSION=auto

# Bench dev ports (used by local-ports override; range supports bench's dynamic +1 allocation)
FRAPPE_WEB_PORT=8000
FRAPPE_SOCKETIO_PORT=9000
FRAPPE_WEB_PORT_LAST=8005
FRAPPE_SOCKETIO_PORT_LAST=9005

# Local dev — bind to loopback only (templates/docker/compose.local-ports.yml)
HOST_BIND=127.0.0.1

# HTTPS / Traefik — only needed with compose.non-prod-https.yaml
HTTP_PUBLISH_PORT=80
HTTPS_PUBLISH_PORT=443
```

Traefik-specific settings (`letsencrypt_email`, `caServer`, entrypoints) are configured in `devops/traefik-static.yml` — see [Traefik / HTTPS](traefik-ssl.md).
