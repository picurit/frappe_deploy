# Traefik / HTTPS Setup

This document covers setting up a remote development environment with TLS termination via Traefik.

## Overview

The `templates/docker/compose.non-prod-https.yaml` override adds:

1. **Traefik proxy service** — listens on ports 80/443, terminates TLS, routes traffic to bench containers over the Docker network.
2. **Traefik's file provider** — routing is declared entirely in `devops/traefik/` YAML files, not Docker labels. Traefik hot-reloads that directory, so adding a bench never requires a restart.
3. **ACME / Let's Encrypt** — automatic certificate issuance for production domains.

No host ports are published on any bench container. Traefik reaches each one over the shared Docker network by container name (`http://frappe:<port>`).

Because routing is file-based, Traefik never touches the Docker socket — there's no `/var/run/docker.sock` mount and no `--providers.docker` flag. That's a meaningful reduction in attack surface for a proxy that's meant to be internet-facing.

> **Do not** combine this override with `templates/docker/compose.local-ports.yml`. The local-ports override publishes host ports that would bypass TLS.

## Traefik two-layer architecture

Traefik separates configuration into two layers:

| Layer | File | Loaded | Changes |
|-------|------|--------|---------|
| **Static** | `devops/traefik/traefik-static.yml` | Once at startup | Requires restart |
| **Dynamic** | `devops/traefik/bench-XX.yml`, `extra-services-XX.yml` | Hot-reloaded | Automatic |

**Static** defines HOW Traefik starts: entrypoints (ports), providers (where to find dynamic config), certificate resolvers.

**Dynamic** defines WHAT Traefik routes: routers (domain → service), services (backend URLs).

```
Request → Static (port 443, TLS) → Dynamic (Host rule → service) → frappe:8000
```

## Required `.env` variables

At minimum, set these in your `.env`:

```env
LETSENCRYPT_EMAIL=admin@example.com
```

Optional:

```env
HTTP_PUBLISH_PORT=80
HTTPS_PUBLISH_PORT=443
ACME_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
```

See [Environment Variables](environment-variables.md) for the full reference. **Note:** hostnames and bench ports are NOT in `.env` — they're configured in the `devops/traefik/` files (see below).

## Required setup (do once per checkout)

### Step 1: Create the Traefik static config

```bash
cp templates/traefik/example.static.yml devops/traefik/traefik-static.yml
```

Then edit the file to match your deployment. The template uses Go template syntax for env var interpolation:

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
  vite:
    address: ":{{ env "VITE_PORT" | default "8080" }}"

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  main-resolver:
    acme:
      httpChallenge:
        entryPoint: web
      email: {{ env "LETSENCRYPT_EMAIL" }}
      storage: /letsencrypt/acme.json
      caServer: {{ env "ACME_CA_SERVER" | default "https://acme-v02.api.letsencrypt.org/directory" }}
```

**Adding/removing entrypoints:** edit this file only. No compose re-render needed — restart the proxy container to pick up static changes.

### Step 2: Create the first bench's routing file

```bash
cp templates/traefik/example.bench.yml devops/traefik/bench-00.yml
```

Then edit the file and fill in:
- **Your hostname** (e.g. `dev.example.com`) — must match DNS pointing at this server's IP
- **Your bench's ports** — check them in `sites/common_site_config.json` or `bench start` console (usually 8000 for web, 9000 for socketio)

The template already defaults to bench 0 (`bench0-web`/`bench0-socketio`), so no router/service renaming is needed for `bench-00.yml`. Example of the modified file:

```yaml
http:
  routers:
    bench0-web:
      rule: "Host(`dev.example.com`)"
      # ... (rest stays the same)
  services:
    bench0-web:
      loadBalancer:
        servers:
          - url: "http://frappe:8000"
    bench0-socketio:
      loadBalancer:
        servers:
          - url: "http://frappe:9000"
```

**Skipping this step:** Traefik starts but has no route to the bench — every request returns 404.

## Rendering the Compose file

```bash
docker compose \
  --project-name dev-bench \
  -f non.prod.compose.yml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f templates/docker/compose.non-prod-https.yaml \
  -f templates/docker/compose.uid-gid.yml \
  -f templates/docker/compose.dev.yml \
  -f devops/compose.deploy-overrides.yml \
  config > devops/docker/dev-ssl.docker-compose.yml

docker compose -f devops/docker/dev-ssl.docker-compose.yml up -d
```

The `devops/compose.deploy-overrides.yml` file is optional and gitignored — it adds deployment-specific overrides like extra ports or entrypoints. See [Architecture](architecture.md) for details.

## How Traefik routing works

Every bench — bench 0, 1, 2, ... — is routed through Traefik's **file provider**, reading from `devops/traefik/*.yml` (mounted read-only, watched for changes):

```yaml
# In traefik-static.yml
providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true
```

### Bench 0 — `devops/traefik/bench-00.yml`

Two routers are declared (one YAML file):

| Router | Matches | Internal port | Purpose |
|--------|---------|---------------|---------|
| `bench0-web` | `Host(...)` | Your web port (usually 8000) | Site pages, REST/RPC API |
| `bench0-socketio` | `Host(...) && PathPrefix(/socket.io)`, `priority: 100` | Your socketio port (usually 9000) | Realtime / WebSocket |

The `priority: 100` makes `bench0-socketio` always win over `bench0-web` for `/socket.io` requests.

This file is a **literal, manually-edited YAML file** — no templating, no variable substitution. It's created by copying `templates/traefik/example.bench.yml` and editing the hostname and ports. That's it. **Bench 0 is routed exactly like bench 1, bench 2, or any other bench — no special mechanism. The `bench-00` name is just the bench number, zero-padded for alphabetic sorting in the directory.**

Multiple **sites** in this one bench share the port — Frappe resolves the site from the `Host` header, so just list every hostname in the rule:

```yaml
bench0-web:
  rule: "Host(`a.example.com`) || Host(`b.example.com`)"
```

### Why a port *range* can't be given to Traefik

Traefik decides the backend **from the router's `Host`/path rule, never from the port**, and then load-balances across a service's `servers`. If one service were pointed at a range (`8000..8005`), each site's traffic would be spread across *every* bench and land on the wrong one most of the time. So "multiple benches behind TLS" is inherently **N distinct `domain → port` mappings**, one router+service pair per bench — never a range.

Contrast with local dev (`templates/docker/compose.local-ports.yml`), where you address a bench *by port* (`localhost:8001`); there, publishing a range works perfectly because you pick the port yourself.

### Adding more benches — `devops/traefik/bench-01.yml`, `bench-02.yml`, etc.

Additional benches (bench 1, bench 2, ...) are added **without touching any compose file, restarting the proxy, or re-rendering compose**, by dropping a new file into `devops/traefik/`. The naming convention is `bench-XX.yml` where XX is a two-digit bench number (this is a local convention, not a Traefik requirement):

1. Copy the template to a new file following the `bench-XX.yml` naming convention — one file per bench, so team members can add or remove their own bench independently:

   ```bash
   cp templates/traefik/example.bench.yml devops/traefik/bench-01.yml  # bench 1
   cp templates/traefik/example.bench.yml devops/traefik/bench-02.yml  # bench 2
   ```

2. Edit the file (e.g., `bench-01.yml`): replace the placeholder hostname and ports with the bench's real values. Check its `sites/common_site_config.json` or the `bench start` console log.

3. Rename the router/service keys to match the bench number (the template has `bench0-web`/`bench0-socketio` as placeholders):
   - For `bench-01.yml` (bench 1): `bench0-web` → `bench1-web`, `bench0-socketio` → `bench1-socketio`
   - For `bench-02.yml` (bench 2): `bench0-web` → `bench2-web`, `bench0-socketio` → `bench2-socketio`

   ```yaml
   http:
     routers:
       bench1-web:
         rule: "Host(`b.example.com`)"
         entryPoints: [websecure]
         service: bench1-web
         tls: { certResolver: main-resolver }
       bench1-socketio:
         rule: "Host(`b.example.com`) && PathPrefix(`/socket.io`)"
         entryPoints: [websecure]
         service: bench1-socketio
         priority: 100
         tls: { certResolver: main-resolver }
     services:
       bench1-web:
         loadBalancer: { servers: [ { url: "http://frappe:8001" } ] }
       bench1-socketio:
         loadBalancer: { servers: [ { url: "http://frappe:9001" } ] }
   ```

4. Save. Traefik was started with `--providers.file.watch=true`, so the new routes appear automatically — no fixed slot count.

5. To remove a bench, delete (or move out) its file — Traefik drops the routes on the next reload.

This scales to any number of benches. Traefik loads every `*.yml` / `*.yaml` / `*.toml` under the directory and ignores everything else. The shipped template lives outside `devops/traefik/` (in `templates/traefik/`), so it never gets picked up by Traefik. `certResolver: main-resolver` is the same ACME resolver used by all benches, so every bench gets real certs in production and the self-signed fallback offline, identically.

`devops/traefik/*.yml` and `*.yaml` are gitignored, the same pattern as `.env`/`example.env` — each deployment's real routing is local to that checkout. The tracked template is `templates/traefik/example.bench.yml`.

### Adding extra services — `devops/traefik/extra-services-XX.yml`

For services that need their own Traefik entrypoint (e.g., Vite dev server on port 8080):

1. Ensure the entrypoint exists in `devops/traefik/traefik-static.yml`:

   ```yaml
   entryPoints:
     vite:
       address: ":{{ env "VITE_PORT" | default "8080" }}"
   ```

2. Create a dynamic routing file:

   ```bash
   cp templates/traefik/example.bench.yml devops/traefik/extra-services-00.yml
   ```

3. Edit the file to add the extra router:

   ```yaml
   http:
     routers:
       bench0-vite:
         rule: "Host(`dev.example.com`)"
         entryPoints: [vite]
         service: bench0-vite
         tls:
           certResolver: main-resolver
     services:
       bench0-vite:
         loadBalancer:
           servers:
             - url: "http://frappe:8080"
   ```

4. If publishing the port through the proxy, add it to `devops/compose.deploy-overrides.yml`:

   ```yaml
   services:
     proxy:
       ports:
         - "${VITE_PORT:-8080}:8080"
   ```

## Certificate behavior by environment

### Production (public IP + real DNS)

On a server with a public IP and DNS pointing your hostname at it, Traefik obtains real Let's Encrypt certificates automatically via HTTP-01 challenge. The default `ACME_CA_SERVER` points to Let's Encrypt production:

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
