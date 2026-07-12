# Frappe Deploy

A Docker-based deployment toolkit for [Frappe Framework](https://frappeframework.com/). Each target environment — local development with open ports, remote development behind HTTPS, or pre-production with automatic restarts — is built by merging a base Compose file with small, composable fragments from `templates/`.

The final rendered file lands in `devops/docker/`, along with any per-deployment config (like Traefik routing files in `devops/traefik/`). Everything in `devops/` is git-ignored except `.gitkeep` placeholders, keeping generated artifacts and local config out of version control while preserving a single source of truth for every configuration variant.

A custom bench image (`images/bench/`) extends the upstream `frappe/bench` image to support runtime UID/GID remapping, so bind-mounted volumes stay writable regardless of the host user's numeric IDs — no more chown'ing directories to 1000:1000.

---

## Prerequisites

- **Docker Engine** with the Compose v2 plugin `docker compose` or the legacy `docker-compose`
- **Git** (needed to clone the repository and initialize the `frappe_docker` submodule)
- Approximately **2 GB of free disk** for the bench image and initial bench dependencies

## Quick Start

**1. Clone the repository with submodules:**

```bash
git clone --recurse-submodules https://github.com/picurit/frappe_deploy.git
cd frappe_deploy
```

If you already cloned without `--recurse-submodules`, initialize the submodule manually:

```bash
git submodule update --init --recursive
```

**2. Create your environment file:**

```bash
cp example.env .env
```

Edit `.env` to set at least `USERID` and `GROUPID` to match your host user (run `id -u` and `id -g` to find them). See [Environment Variables](docs/environment-variables.md) for the full reference.

**3. Build the custom bench image (optional, only if using custom UID/GID):**

```bash
docker build --no-cache -t bench:latest images/bench/
```

From here, pick the scenario that matches what you're setting up.

### Scenario A: Local development (open ports, no TLS)

For working on your own machine — the site is reachable straight on `localhost`, no proxy involved.

**4. Render a Compose file and start the stack:**

```bash
docker compose \
  --project-name dev-bench \
  -f non.prod.compose.yml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f templates/docker/compose.uid-gid.yml \
  -f templates/docker/compose.local-ports.yml \
  -f templates/docker/compose.dev.yml \
  config > devops/docker/dev.docker-compose.yml

docker compose -f devops/docker/dev.docker-compose.yml up -d
```

**5. Open a shell inside the bench container and start the dev server:**

```bash
docker compose -f devops/docker/dev.docker-compose.yml exec frappe bash
bench start
```

The site is available at **http://localhost:8000**.

### Scenario B: Shared remote development (cloud server, HTTPS via Traefik)

For a team-shared dev environment on a cloud VM with a public IP and a real domain — Traefik terminates TLS (real Let's Encrypt certs when DNS + public IP are in place) and routes to the bench container; no bench ports are published on the host.

**4. Set the HTTPS-specific `.env` variables** (in addition to `USERID`/`GROUPID` from step 2):

```env
LETSENCRYPT_EMAIL=team@example.com
```

That's it for `.env`. Hostnames and bench ports are configured in the Traefik dynamic config files, not here — see step 5 below.

**5. Create and configure the first bench's Traefik routing file:**

This is like creating `.env` from `example.env` — a per-deployment file that's gitignored, created by copying a tracked template. The template is `templates/traefik/example.bench.yml` — **every bench uses the same template**, whether it's bench 0, 1, or 2. Just copy it with a `bench-00` name for sorting:

```bash
# Copy the template to create the first bench's config
cp templates/traefik/example.bench.yml devops/traefik/bench-00.yml

# Edit the file and fill in:
# - Your hostname: change Host(`b.example.com`) to your real domain
# - Your bench ports: change 8000/9000 to match your bench's actual ports
#   (check sites/common_site_config.json or the `bench start` log)
nano devops/traefik/bench-00.yml
```

On a machine with no public IP (e.g. a local workstation), Traefik falls back to its self-signed certificate and the stack is still reachable over `https://`, just with a browser warning — see [Certificate behavior by environment](docs/traefik-ssl.md#certificate-behavior-by-environment).

**Skipping this step:** Traefik starts but has no route to the bench — every request returns 404.

**6. Render a Compose file and start the stack:**

```bash
docker compose \
  --project-name dev-bench \
  -f non.prod.compose.yml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f templates/docker/compose.non-prod-https.yaml \
  -f templates/docker/compose.uid-gid.yml \
  -f templates/docker/compose.dev.yml \
  config > devops/docker/dev-ssl.docker-compose.yml

docker compose -f devops/docker/dev-ssl.docker-compose.yml up -d
```

**7. Open a shell inside the bench container and start the dev server:**

```bash
docker compose -f devops/docker/dev-ssl.docker-compose.yml exec frappe bash
bench start
```

The site is available at **https://dev.example.com** (or whatever hostname you set in step 5).

**Adding more benches (team members' instances, e.g. bench 1 on ports 8001/9001, bench 2 on 8002/9002):** Add one file under `devops/traefik/` from `templates/traefik/example.bench.yml` — no compose re-render, no restart. Example: `cp templates/traefik/example.bench.yml devops/traefik/bench-01.yml`, then edit it. See [Adding more benches](docs/traefik-ssl.md#adding-more-benches--devopstraefikbench-01yml-bench-02yml-etc) in the traefik docs.

---

## Documentation

| Document | Description |
|----------|-------------|
| [Installation](docs/installation.md) | Full prerequisites, clone instructions, and first-run walkthrough |
| [Architecture](docs/architecture.md) | How the Compose override layering works and the directory layout |
| [Custom UID/GID](docs/custom-uid-gid.md) | Why the custom bench image exists and how runtime UID/GID remapping works |
| [Traefik / HTTPS](docs/traefik-ssl.md) | Setting up remote development with TLS via Traefik and Let's Encrypt |
| [Environment Variables](docs/environment-variables.md) | Complete reference of every `.env` variable with defaults and examples |
