# Traefik / HTTPS Setup

This document covers setting up a remote development environment with TLS termination via Traefik.

## Overview

The `overrides/compose.non-prod-https.yaml` override adds:

1. **Traefik proxy service** — listens on ports 80/443, terminates TLS, routes traffic to the bench container over the Docker network.
2. **Traefik labels on the `frappe` service** — tell Traefik which ports to forward to and which hostnames to match.
3. **ACME / Let's Encrypt** — automatic certificate issuance for production domains.

No host ports are published on the bench container itself. Traefik reaches the container over the shared Docker network using the `loadbalancer.server.port` labels.

> **Do not** combine this override with `compose.local-ports.yml`. The local-ports override publishes host ports that would bypass TLS.

## Required `.env` variables

At minimum, set these in your `.env`:

```env
SITES_RULE=Host(`erp.example.com`)
LETSENCRYPT_EMAIL=admin@example.com
```

Optional overrides:

```env
HTTP_PUBLISH_PORT=80
HTTPS_PUBLISH_PORT=443
ACME_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
```

See [Environment Variables](environment-variables.md) for the full reference.

## Rendering the Compose file

```bash
docker compose \
  --project-name dev-bench \
  -f non.prod.compose.yml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.non-prod-https.yaml \
  -f overrides/compose.uid-gid.yml \
  -f overrides/compose.dev.yml \
  config > devops/dev-ssl.docker-compose.yml
```

## How Traefik routing works

Two routers are declared on the `frappe` service:

| Router | Matches | Internal port | Purpose |
|--------|---------|---------------|---------|
| `frappe-web` | `SITES_RULE` | 8000 | Site pages, REST/RPC API |
| `frappe-socketio` | `SITES_RULE` + `PathPrefix(/socket.io)` | 9000 | Realtime / WebSocket |

The socketio rule is strictly longer than the web rule, so Traefik's length-based priority routes `/socket.io` to port 9000 and everything else to 8000 without any explicit priority setting.

### Multi-site

Frappe resolves the site from the `Host` header, so multiple sites share port 8000. List all hostnames in `SITES_RULE`:

```env
SITES_RULE=Host(`a.example.com`) || Host(`b.example.com`)
```

No per-site ports are needed.

## Certificate behavior by environment

### Production (public IP + real DNS)

On a server with a public IP and DNS pointing `SITES_RULE` at it, Traefik obtains real Let's Encrypt certificates automatically via HTTP-01 challenge. The default `ACME_CA_SERVER` points to Let's Encrypt production:

```env
ACME_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
```

### Local / no public IP (self-signed fallback)

On a workstation without internet egress or a public IP, HTTP-01 validation cannot complete. Traefik falls back to its built-in self-signed certificate. The stack still starts and is reachable over `https://`, but the browser will show a certificate warning.

To avoid burning Let's Encrypt production rate limits while testing, point `ACME_CA_SERVER` at the staging directory:

```env
ACME_CA_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
```

Staging certificates are also self-signed (browser warning), but they do not count against production rate limits.

## Traefik proxy configuration details

The proxy service uses the official `traefik:v3.6` image with these key settings:

```yaml
command:
  - --providers.docker=true                         # auto-discover containers with labels
  - --providers.docker.exposedbydefault=false        # only expose containers with traefik.enable=true
  - --entrypoints.web.address=:80                    # HTTP listener
  - --entrypoints.web.http.redirections.entrypoint.to=websecure   # redirect HTTP -> HTTPS
  - --entrypoints.web.http.redirections.entrypoint.scheme=https
  - --entrypoints.websecure.address=:443             # HTTPS listener
  - --certificatesresolvers.main-resolver.acme.httpchallenge=true
  - --certificatesresolvers.main-resolver.acme.httpchallenge.entrypoint=web
  - --certificatesresolvers.main-resolver.acme.email=${LETSENCRYPT_EMAIL}
  - --certificatesresolvers.main-resolver.acme.storage=/letsencrypt/acme.json
  - --certificatesresolvers.main-resolver.acme.caserver=${ACME_CA_SERVER}
ports:
  - ${HTTP_PUBLISH_PORT:-80}:80
  - ${HTTPS_PUBLISH_PORT:-443}:443
volumes:
  - cert-data:/letsencrypt
  - /var/run/docker.sock:/var/run/docker.sock:ro    # required for Docker provider
```

The Docker socket is mounted read-only so Traefik can discover labeled containers. The `cert-data` volume persists ACME certificates across container restarts.
