# Installation

This guide walks through every step from a bare machine to a running Frappe bench in Docker.

## Prerequisites

### Docker Engine and Compose

Docker Engine **24.0+** and the Compose **v2** plugin are required. Verify your installation:

```bash
docker --version    # Docker version 24.0+, or later
docker compose version  # Docker Compose version v2.x+
```

If you only have the legacy `docker-compose` (hyphenated, Python-based), install the Compose plugin via your package manager or the [official Docker install docs](https://docs.docker.com/engine/install/).

### Git

Git is needed to clone the repository **and** to initialize the `frappe_docker` submodule that ships the upstream Compose overrides and images.

### Disk space

Reserve approximately **2 GB** for the bench image layers, MariaDB image, Redis image, and the initial `bench init` dependencies (Python packages, Node modules, Frappe framework source).

## Cloning the repository

The `frappe_docker` directory is a **git submodule** pointing to the official [frappe/frappe_docker](https://github.com/frappe/frappe_docker) repository. It must be initialized for the Compose overrides (`frappe_docker/overrides/compose.mariadb.yaml`, etc.) to exist on disk.

### Fresh clone (recommended)

```bash
git clone --recurse-submodules <repository-url>
cd frappe_deploy
```

The `--recurse-submodules` flag initializes the submodule in a single step.

### Existing clone without submodules

If you already cloned the repository without `--recurse-submodules`:

```bash
cd frappe_deploy
git submodule update --init --recursive
```

### Verify the submodule

```bash
ls frappe_docker/overrides/compose.mariadb.yaml
```

If the file exists, the submodule is initialized correctly. If it is missing, re-run the submodule update command.

## Environment file

Copy the example and customize it:

```bash
cp example.env .env
```

At minimum, set `USERID` and `GROUPID` to match your host user so that bind-mounted files remain writable inside the container:

```bash
# Find your host UID and GID
id -u   # e.g. 1001
id -g   # e.g. 1001
```

Then edit `.env`:

```env
USERID=1001
GROUPID=1001
```

See [Environment Variables](environment-variables.md) for the full reference of every variable.

## Building the custom bench image

The project includes a thin wrapper image (`images/bench/`) that extends the upstream `frappe/bench` image with runtime UID/GID remapping. Build it if you need custom UID/GID support or if you want the entrypoint wrapper:

```bash
docker build --no-cache -t bench:latest images/bench/
```

If you are fine with the default UID/GID 1000:1000, you can skip this step and the Compose files will use the upstream `frappe/bench:latest` image directly.

## Rendering a Compose file

Each target environment has a specific `docker compose ... config` command that merges the base file with the right set of templates from `templates/docker/`. The rendered file is written to `devops/docker/`.

### Local development (open ports)

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
```

### Remote development (HTTPS/Traefik)

Requires a static config file `devops/traefik/traefik-static.yml` and a routing file `devops/traefik/bench-00.yml` (see [Traefik / HTTPS](traefik-ssl.md) for setup):

```bash
# First, create the Traefik static config and bench routing file
cp templates/traefik/example.static.yml devops/traefik/traefik-static.yml
cp templates/traefik/example.bench.yml devops/traefik/bench-00.yml
# Then edit both files with your email, hostname, and ports

# Then render the compose file
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
```

### Pre-production

```bash
docker compose \
  --project-name pre-bench \
  -f non.prod.compose.yml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f templates/docker/compose.pre.yml \
  config > devops/docker/pre.docker-compose.yml
```

> **Important:** Always run the `config` command from the repository root so that `${PWD}`-based volume paths resolve correctly.

## Starting the stack

```bash
docker compose -f devops/docker/dev.docker-compose.yml up -d
```

Wait for the `configurator` service to finish (it runs `bench init` on first boot — this can take a few minutes). You can watch progress with:

```bash
docker compose -f devops/docker/dev.docker-compose.yml logs -f configurator
```

Once the configurator exits and the `frappe` service is running, open a shell:

```bash
docker compose -f devops/docker/dev.docker-compose.yml exec frappe bash
```

Inside the container, start the development server:

```bash
bench start
```

The site is available at **http://localhost:8000** (or the port configured in your overrides).

## Verifying the installation

1. **Container health:** `docker compose -f devops/docker/dev.docker-compose.yml ps` — all services should be `Up` or `Exited 0` (configurator).
2. **Bench version:** inside the container, run `bench version` to confirm Frappe is installed.
3. **Browser:** navigate to `http://localhost:8000`. The Frappe/ERPNext setup wizard should appear.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Permission denied` during `bench init` | UID/GID mismatch between host volume and container user | Set `USERID`/`GROUPID` in `.env` and rebuild with `compose.uid-gid.yml` |
| `fatal: not a git repository: /workspace/../.git/modules/frappe_docker` | Submodule `.git` pointer leaking into the container | Ensure the volume mounts `frappe_docker/development/` (not the whole submodule) — this is already handled in `non.prod.compose.yml` |
| All requests return 404 with HTTPS (Traefik) | Missing or misconfigured `devops/traefik/bench-00.yml` | Ensure `devops/traefik/bench-00.yml` exists (copy from `templates/traefik/example.bench.yml`) and has the correct hostname and bench ports |
| Traefik certificate warning in browser (HTTPS) | Normal on workstations without public IP | Traefik falls back to self-signed cert; add hostname to your hosts file or use real DNS + public IP to get trusted certs |
| Configurator takes a long time | First run downloads Frappe source + Python dependencies | This is normal; subsequent starts skip `bench init` if the directory already exists |
