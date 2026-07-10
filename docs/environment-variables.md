# Environment Variables

All configuration is driven by a single `.env` file in the repository root. Copy the template:

```bash
cp env.example .env
```

Below is the complete reference.

## Runtime UID/GID

Used by `overrides/compose.uid-gid.yml` and the custom bench entrypoint.

| Variable | Default | Description |
|----------|---------|-------------|
| `USERID` | `1000` | UID to assign to the `frappe` user at container start. Set to your host user's UID (`id -u`) so bind-mounted files are writable. |
| `GROUPID` | `1000` | GID to assign to the `frappe` user. If different from `USERID`, a new group `frappegid` is created. |

If both values match the image defaults (1000:1000), the entrypoint skips remapping entirely — no performance overhead.

## Local host ports

Used by `overrides/compose.local-ports.yml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST_BIND` | `127.0.0.1` | Network interface the bench ports bind to. Use `0.0.0.0` to expose to the LAN. |

The published ports are always 8000-8005 (web) and 9000-9005 (socketio). Only the bind address changes.

## HTTPS / Traefik

Used by `overrides/compose.non-prod-https.yaml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `SITES_RULE` | *(required)* | Traefik router rule for hostname matching. Single site: `` Host(`erp.example.com`) ``. Multiple sites: `` Host(`a.example.com`) \|\| Host(`b.example.com`) ``. |
| `LETSENCRYPT_EMAIL` | *(required)* | Email address for Let's Encrypt certificate notifications. Passed verbatim to the ACME resolver. |
| `HTTP_PUBLISH_PORT` | `80` | Host port for Traefik's HTTP entrypoint. |
| `HTTPS_PUBLISH_PORT` | `443` | Host port for Traefik's HTTPS entrypoint. |
| `ACME_CA_SERVER` | `https://acme-v02.api.letsencrypt.org/directory` | ACME directory URL. Use the [staging URL](https://letsencrypt.org/docs/staging-environment/) (`https://acme-staging-v02.api.letsencrypt.org/directory`) while testing to avoid rate limits. |

## Custom image tags

Used by `non.prod.compose.yml` and `overrides/compose.uid-gid.yml`.

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

# Local dev — bind to loopback only
HOST_BIND=127.0.0.1

# HTTPS / Traefik — only needed with compose.non-prod-https.yaml
SITES_RULE=Host(`erp.example.com`)
LETSENCRYPT_EMAIL=admin@example.com
HTTP_PUBLISH_PORT=80
HTTPS_PUBLISH_PORT=443
ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
```
