# Architecture

This document explains how the Compose override layering works and how the project is organized.

## Directory layout

```
frappe_deploy/
├── non.prod.compose.yml            # Base Compose for all non-production environments
├── example.env                     # Template for .env
├── .env                            # Your local overrides (git-ignored)
├── images/
│   └── bench/
│       ├── Dockerfile              # Custom bench image with UID/GID remapping
│       └── entrypoint.sh           # Runtime entrypoint that remaps the frappe user
├── overrides/                      # Compose fragments for this project
│   ├── compose.dev.yml             # Development restart policy (restart: no)
│   ├── compose.pre.yml             # Pre-production restart policy (restart: on-failure)
│   ├── compose.local-ports.yml     # Publishes bench ports to the host (opt-in)
│   ├── compose.uid-gid.yml         # Builds the custom bench image + sets USERID/GROUPID
│   └── compose.non-prod-https.yaml # Traefik proxy + TLS for remote dev (file-provider routing)
├── frappe_docker/                  # Git submodule — upstream frappe_docker
│   ├── overrides/
│   │   ├── compose.mariadb.yaml    # MariaDB service
│   │   ├── compose.redis.yaml      # Redis services (cache, queue, socketio)
│   │   └── ...
│   └── development/                # Bind-mounted into the bench container (gitignored)
├── devops/                         # All per-deployment output and config (git-ignored except example.* templates)
│   ├── traefik/
│   │   ├── example.bench.yml       # Template for all benches (bench-00.yml, bench-01.yml, bench-02.yml, ...)
│   │   └── bench-00.yml            # Real per-deployment routing files (git-ignored)
│   ├── dev.docker-compose.yml      # Rendered Compose files (git-ignored)
│   ├── dev-ssl.docker-compose.yml
│   └── pre.docker-compose.yml
└── docs/                           # This documentation
```

Everything under `devops/` other than `example.*` templates is git-ignored: rendered Compose files and real per-deployment Traefik routing files are local to each checkout, the same pattern as `.env`/`example.env`.

## Compose override layering

Docker Compose supports merging multiple `-f` files. Later files override or extend earlier ones. This project exploits that to compose environments from small, focused fragments:

```
non.prod.compose.yml                       ← base (services, volumes, workspace)
  + frappe_docker/overrides/compose.mariadb.yaml   ← adds MariaDB
  + frappe_docker/overrides/compose.redis.yaml     ← adds Redis
  + overrides/compose.uid-gid.yml                  ← builds custom image, sets USERID/GROUPID
  + overrides/compose.local-ports.yml              ← publishes host ports
  + overrides/compose.dev.yml                      ← sets restart policy
  ─────────────────────────────────────────────────
  = devops/dev.docker-compose.yml                  ← final, self-contained file
```

### Why this pattern?

1. **Separation of concerns.** Each override handles one thing (database, cache, ports, TLS, UID remapping). You can swap or omit any of them without touching the others.

2. **Opt-in host ports.** Docker Compose file merging can **add** entries to a list (like `ports:`) but can never **remove** them. If the base file declared `ports: ["8000:8000"]`, every derived environment — including the Traefik/SSL one — would expose those ports, bypassing TLS. Instead, ports are absent from the base file and added only via `compose.local-ports.yml`.

3. **No hand-editing generated files.** The `config` command produces a single file with absolute paths. Once rendered, it works from any working directory.

## Services

### `configurator`

A one-shot service that runs `bench init` on the first boot. It:

1. Checks if the bench directory (`frappe-bench-X.Y.Z`) already exists.
2. If not, runs `bench init` to clone Frappe and set up the Python virtualenv.
3. Configures `db_host`, `redis_cache`, `redis_queue`, and `redis_socketio` via `bench set-config`.
4. Exits.

On subsequent boots, if the directory already exists, the configurator exits immediately.

### `frappe`

The main interactive service. It runs `sleep infinity` by default, keeping the container alive so you can `docker exec` into it and run `bench start`, `bench new-site`, etc.

In the HTTPS variant, routing to this service is declared in `devops/traefik/bench-00.yml`, `bench-01.yml`, `bench-02.yml`, etc. — literal YAML files (no templating), created by copying the tracked template and editing them with hostnames and ports. See [Traefik / HTTPS](traefik-ssl.md) for details.

## Volume mounts

The `workspace` volume is a bind mount of `frappe_docker/development/` from the host:

```yaml
volumes:
  workspace:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${PWD}/frappe_docker/development
```

Only the `development/` subdirectory is mounted — **not** the entire `frappe_docker` submodule. This is intentional: mounting the whole submodule would leak its `.git` pointer file (`gitdir: ../.git/modules/frappe_docker`) into the container at `/workspace/.git`, causing every git command inside the bench (e.g. `git ls-remote` during `bench init`) to fail with "fatal: not a git repository".

The `development/` directory is git-ignored, so anything created inside it (bench sites, apps, etc.) stays local and does not affect the submodule.
