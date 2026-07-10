# Generated Compose Files

This directory holds Docker Compose files that are **rendered artifacts** — produced by running the `docker compose ... config` command from the repository root, never edited by hand, and never committed to version control.

## Why this directory exists

The project uses a Compose override layering pattern: a base file (`non.prod.compose.yml`) is merged with several override fragments from `overrides/` and `frappe_docker/overrides/`. The merged result is a single self-contained Compose file with absolute paths baked in, so `docker compose -f devops/<name>.docker-compose.yml` can run from any working directory.

Keeping these rendered files in a dedicated git-ignored folder avoids polluting the repo root with generated artifacts while still allowing you to inspect or debug them locally.

## Generated files

| File | Environment | Key overrides applied |
|------|-------------|----------------------|
| `dev.docker-compose.yml` | Local development | MariaDB, Redis, UID/GID remap, local port publishing, dev restart policy |
| `dev-ssl.docker-compose.yml` | Remote development (HTTPS) | MariaDB, Redis, UID/GID remap, Traefik + TLS, dev restart policy |
| `pre.docker-compose.yml` | Pre-production | MariaDB, Redis, pre-prod restart policy |

These files are listed here for reference only; the actual generation commands live in the [main README](../README.md).

## How to regenerate

Run the `docker compose ... config` command from the **repository root** so that `${PWD}`-based volume paths resolve correctly. The rendered file bakes in absolute paths, which is why the later `docker compose -f devops/<name>.docker-compose.yml up/exec/down` commands can be executed from anywhere on the host.

Example (local dev):

```bash
docker compose \
  --project-name dev-bench \
  -f non.prod.compose.yml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f overrides/compose.uid-gid.yml \
  -f overrides/compose.local-ports.yml \
  -f overrides/compose.dev.yml \
  config > devops/dev.docker-compose.yml
```

## Gitignore rules

The `.gitignore` entries are:

```
devops/*
!devops/README.md
```

This keeps the folder tracked (so it exists after clone) while ignoring every generated Compose file inside it.
