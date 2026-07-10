# Frappe Deploy

A Docker-based deployment toolkit for [Frappe Framework](https://frappeframework.com/). That provides small, composable override fragments that you layer together to produce exactly the environment you need, local development with open ports, remote development behind HTTPS, or pre-production with automatic restarts.

Each target environment is built by merging a base Compose file with a curated set of overrides. The final rendered file lands in the `devops/` directory, which stays git-ignored except for its own README. This keeps generated artifacts out of version control while preserving a single source of truth for every configuration variant.

A custom bench image (`images/bench/`) extends the upstream `frappe/bench` image to support runtime UID/GID remapping, so bind-mounted volumes stay writable regardless of the host user's numeric IDs — no more chown'ing directories to 1000:1000.

---

## Prerequisites

- **Docker Engine 24+** with the Compose v2 plugin (`docker compose` — not the legacy `docker-compose`)
- **Git** (needed to clone the repository and initialize the `frappe_docker` submodule)
- Approximately **2 GB of free disk** for the bench image and initial bench dependencies

## Quick Start

**1. Clone the repository with submodules:**

```bash
git clone --recurse-submodules <repository-url>
cd frappe_deploy
```

If you already cloned without `--recurse-submodules`, initialize the submodule manually:

```bash
git submodule update --init --recursive
```

**2. Create your environment file:**

```bash
cp env.example .env
```

Edit `.env` to set at least `USERID` and `GROUPID` to match your host user (run `id -u` and `id -g` to find them). See [Environment Variables](docs/environment-variables.md) for the full reference.

**3. Build the custom bench image (optional, only if using custom UID/GID):**

```bash
docker build --no-cache -t bench:latest images/bench/
```

**4. Render a Compose file and start the stack:**

```bash
# Local development (ports on localhost)
docker compose \
  --project-name dev-bench \
  -f non.prod.compose.yml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.uid-gid.yml \
  -f overrides/compose.local-ports.yml \
  -f overrides/compose.dev.yml \
  config > devops/dev.docker-compose.yml

docker compose -f devops/dev.docker-compose.yml up -d
```

**5. Open a shell inside the bench container and start the dev server:**

```bash
docker compose -f devops/dev.docker-compose.yml exec frappe bash
bench start
```

The site is available at **http://localhost:8000**.

---

## Documentation

| Document | Description |
|----------|-------------|
| [Installation](docs/installation.md) | Full prerequisites, clone instructions, and first-run walkthrough |
| [Architecture](docs/architecture.md) | How the Compose override layering works and the directory layout |
| [Custom UID/GID](docs/custom-uid-gid.md) | Why the custom bench image exists and how runtime UID/GID remapping works |
| [Traefik / HTTPS](docs/traefik-ssl.md) | Setting up remote development with TLS via Traefik and Let's Encrypt |
| [Environment Variables](docs/environment-variables.md) | Complete reference of every `.env` variable with defaults and examples |
| [Generated Compose Files](devops/README.md) | How rendered Compose files are managed and where they live |
