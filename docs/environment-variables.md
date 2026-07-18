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

**Note:** `letsencrypt_email`, `caServer`, entrypoints, and ACME settings are configured in `devops/traefik/traefik-static.yml` (plain YAML, no templating) — see [Traefik / HTTPS](traefik-ssl.md). Hostnames and bench ports are configured in `devops/traefik/bench-XX.yml`.

## Custom image tags

Used by `non.prod.compose.yml` and `templates/docker/compose.uid-gid.yml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `CUSTOM_IMAGE` | `bench` (uid-gid) / `frappe/bench` (base) | Docker image name for the bench container. |
| `CUSTOM_TAG` | `latest` | Docker image tag. |
| `BASE_IMAGE` | `frappe/bench` | Base image for the custom bench build (uid-gid override). |
| `BASE_TAG` | `latest` | Base image tag for the custom bench build. |

## Database and cache

These are not set in `.env` by default but are referenced in `non.prod.compose.yml` and passed through to the configurator. They are set automatically by the MariaDB and Redis Compose overrides via Docker networking:

| Variable | Used by | Description |
|----------|---------|-------------|
| `DB_HOST` | `non.prod.compose.yml` (configurator) | Hostname of the MariaDB service. |
| `DB_PORT` | `non.prod.compose.yml` (configurator) | Port of the MariaDB service. |
| `REDIS_CACHE` | `non.prod.compose.yml` (configurator) | Redis connection string for caching. |
| `REDIS_QUEUE` | `non.prod.compose.yml` (configurator) | Redis connection string for background job queues. |

These are typically resolved by Docker Compose service discovery (e.g. `db:3306`, `redis-cache:6379`) and do not need to be set manually unless you are connecting to external services.

## Example `.env` file

```env
# UID/GID — match your host user
USERID=1001
GROUPID=1001

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

Traefik-specific settings (`letsencrypt_email`, `caServer`, entrypoints) are configured in `devops/traefik/traefik-static.yml` — see [Traefik / HTTPS](traefik-ssl.md).
