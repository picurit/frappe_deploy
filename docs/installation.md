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

Reserve approximately **5 GB**: the `frappe/bench` image is ~2.8 GB by itself, the MariaDB and Redis images add ~0.5 GB, and each bench created by `bench init` (Python virtualenv, Node modules, Frappe source) takes ~1 GB.

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

## Choosing the bench image and the Frappe version

Two `.env` variables pin the two moving parts, and both have working defaults:

- `BENCH_IMAGE`/`BENCH_TAG` (default `frappe/bench:latest`) select the upstream image that ships the `bench` CLI and the Python/Node toolchain. They mean the same thing in every scenario. `PULL_POLICY` defaults to `never`: stacks that run the upstream image directly (no uid-gid override, e.g. pre-production) need a manual `docker pull frappe/bench:<tag>` before the first `up` and after every tag change. Stacks with the uid-gid override do not, because `docker compose build` fetches a missing base image on its own.
- `FRAPPE_BRANCH` (default `version-16`) is the git ref of `frappe/frappe` that `bench init` clones: a branch for the latest release of that line (`version-16`, `version-15`), or a tag to pin one release (`v15.x.x`, `v16.x.x`). It also names the bench directory (`frappe-bench-<ref>`). `BENCH_PYTHON_VERSION=auto` uses the image's default Python, which the supported branches accept; only set it when a ref needs a different interpreter.

See [Environment Variables](environment-variables.md) for details.

## The custom bench image

The project includes a thin wrapper image (`images/bench/`) that extends the upstream `frappe/bench` image with runtime UID/GID remapping. It is only used when `templates/docker/compose.uid-gid.yml` is part of the merge, and Docker Compose builds it for you from the rendered file, on top of the `BENCH_IMAGE:BENCH_TAG` you selected, under the fixed name `bench:<BENCH_TAG>`:

```bash
docker compose -f devops/docker/dev.docker-compose.yml build
```

`up -d` also builds it automatically when the image is missing. Do not build it with a manual `docker build`, which would ignore the `.env` values. If you are fine with the default UID/GID 1000:1000, omit the uid-gid override and the Compose files will run the upstream image directly.

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

Requires a static config file `devops/traefik-static.yml` and a routing file `devops/traefik/bench-00.yml` (see [Traefik / HTTPS](traefik-ssl.md) for setup):

```bash
# First, create the Traefik static config and bench routing file
cp templates/traefik/example.static.yml devops/traefik-static.yml
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
docker compose -f devops/docker/dev.docker-compose.yml build   # only with the uid-gid override; no-op otherwise
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

Inside the container, create a site the first time (the MariaDB root password is `DB_PASSWORD`, default `123`; `--mariadb-user-host-login-scope=%` lets the site's DB user connect from the bench container), then start the development server:

```bash
cd frappe-bench-$FRAPPE_BRANCH
bench new-site dev.localhost --db-root-password 123 --admin-password admin --mariadb-user-host-login-scope=%   # first time only
bench use dev.localhost
bench start
```

The site is available at **http://localhost:8000** (or the port configured in your overrides).

## Verifying the installation

1. **Container health:** `docker compose -f devops/docker/dev.docker-compose.yml ps` — all services should be `Up` or `Exited 0` (configurator).
2. **Versions:** inside the container, `bench version` lists the installed apps and should show the latest Frappe release of `FRAPPE_BRANCH`; `bench --version` shows the bench CLI that came with the image.
3. **Browser:** navigate to `http://localhost:8000`. The Frappe/ERPNext setup wizard should appear.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Permission denied` during `bench init` | UID/GID mismatch between host volume and container user | Set `USERID`/`GROUPID` in `.env` and rebuild with `compose.uid-gid.yml` |
| `fatal: not a git repository: /workspace/../.git/modules/frappe_docker` | Submodule `.git` pointer leaking into the container | Ensure the volume mounts `frappe_docker/development/` (not the whole submodule) — this is already handled in `non.prod.compose.yml` |
| All requests return 404 with HTTPS (Traefik) | Missing or misconfigured `devops/traefik/bench-00.yml` | Ensure `devops/traefik/bench-00.yml` exists (copy from `templates/traefik/example.bench.yml`) and has the correct hostname and bench ports |
| Traefik certificate warning in browser (HTTPS) | Normal on workstations without public IP | Traefik falls back to self-signed cert; add hostname to your hosts file or use real DNS + public IP to get trusted certs |
| Configurator exits `1` while `bench init` installs Python dependencies (a package fails to build) | The ref in `FRAPPE_BRANCH` requires a different Python than the image's default interpreter (check its `pyproject.toml` `requires-python`) | Set `BENCH_PYTHON_VERSION` in `.env` to one of the versions the image ships (`pyenv versions` inside the container), re-render the Compose file and run `up -d` again. A failed init removes its partial bench directory so the retry starts clean |
| `frappe` container stays in `Created` with `failed to bind host port for 127.0.0.1:8000 ... address already in use` | Another process on the host (commonly a VS Code port forward, or a previous `bench start`) already listens on a port in the published 8000-8005 / 9000-9005 range | Free the port (`ss -ltnp \| grep -E ':(8000\|9000)'` shows the owner; in VS Code, remove it in the **Ports** panel) or move the range via `FRAPPE_WEB_PORT*` / `FRAPPE_SOCKETIO_PORT*` in `.env` |
| Configurator takes a long time | First run downloads Frappe source + Python dependencies | This is normal; subsequent starts skip `bench init` if the directory already exists |
| `No such image: frappe/bench:<tag>` on a stack without the uid-gid override (first start, or after changing `BENCH_TAG`) | `PULL_POLICY=never` (default) never downloads the image the containers run | Run `docker pull frappe/bench:<tag>` once, or set `PULL_POLICY=missing` in `.env` and re-render. Stacks with the uid-gid override are not affected: `docker compose build` fetches the base image itself |
| Configurator runs `bench init` again after you changed `FRAPPE_BRANCH` | The bench directory is named after the ref, so a new value means a new bench | Expected. The old `frappe-bench-<old>` stays untouched next to the new one (and keeps ports 8000/9000; the new bench gets 8001/9001); delete the old directory first if you want the new bench on the default ports |
| `bench update` says nothing to pull / HEAD is detached | `FRAPPE_BRANCH` is a tag, so the checkout is a frozen detached HEAD | Expected for pinned releases. Use a branch (`version-16`) if you want in-place updates |
