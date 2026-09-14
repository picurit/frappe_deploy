# Custom UID/GID

## The problem

The upstream `frappe/bench` image creates a `frappe` user with UID/GID **1000:1000** baked in at build time. When you bind-mount a host directory into the container, the container user (UID 1000) may not match the host user's UID. This causes:

- **Permission denied** errors when the container tries to write to the mounted volume.
- Need to `chown` host directories to 1000:1000, which conflicts with the host user's own UID and requires `sudo` for日常 file operations.
- Inconsistent behavior between VS Code devcontainers (which auto-remap UID/GID) and standalone Docker Compose deployments.

Changing the UID/GID at runtime requires root privileges (for `usermod`/`groupmod`), which is why the base image runs as `frappe` — there is no way to remap without elevated permissions first.

## The solution

A thin wrapper image (`images/bench/Dockerfile`) extends the upstream `frappe/bench` image:

1. Keeps the upstream `USER frappe`; it only adds an `ENTRYPOINT` and the two `USERID`/`GROUPID` defaults.
2. Copies in `entrypoint.sh`, which runs at container start as `frappe` and re-executes itself as root through the passwordless `sudo` the upstream image already grants to that user.
3. As root, the entrypoint validates `USERID`/`GROUPID`, remaps the `frappe` user, re-owns container filesystem entries, then drops privileges back to `frappe` via `setpriv`.

### Dockerfile (`images/bench/Dockerfile`)

```dockerfile
ARG BENCH_IMAGE=frappe/bench     # passed by compose.uid-gid.yml from .env
ARG BENCH_TAG=latest
FROM ${BENCH_IMAGE}:${BENCH_TAG}

ENV USERID=1000
ENV GROUPID=1000

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
```

### entrypoint.sh flow

1. **Validate** — checks that `USERID` and `GROUPID` are positive integers and do not collide with existing system users/groups.
2. **Fast path** — if the requested UID/GID already match the current `frappe` identity (the default 1000:1000 case), skips all remapping and exec's directly.
3. **Remap group** — if `GROUPID` differs from the current GID:
   - If `USERID == GROUPID`, repoints the existing `frappe` group.
   - Otherwise, creates a new group `frappegid` with the target GID.
4. **Remap user** — runs `usermod` to update the `frappe` user's UID and primary GID.
5. **Re-own container files** — scans the entire container filesystem (`find / -xdev`) for files matching the old UID/GID and chowns them to the new identity. Skips host-mounted volumes.
6. **Drop privileges** — exec's the original command as the remapped `frappe` user via `setpriv --reuid=frappe --regid=<group> --init-groups`.

## When to use it

Use the UID/GID override when your host user's UID/GID is **not** 1000:1000 and you need to bind-mount a directory that the container writes to.

### With custom UID/GID

Set `USERID` and `GROUPID` in `.env`, include the override, and let Compose build the image:

```bash
# In .env
USERID=1001
GROUPID=1001

# Render compose with the uid-gid override
docker compose \
  --project-name dev-bench \
  -f non.prod.compose.yml \
  -f frappe_docker/overrides/compose.mariadb.yaml \
  -f frappe_docker/overrides/compose.redis.yaml \
  -f templates/docker/compose.uid-gid.yml \
  -f templates/docker/compose.local-ports.yml \
  -f templates/docker/compose.dev.yml \
  config > devops/docker/dev.docker-compose.yml

# Build the wrapper image from the rendered file (honours BENCH_IMAGE/BENCH_TAG from .env)
docker compose -f devops/docker/dev.docker-compose.yml build
```

### Without custom UID/GID (default 1000:1000)

If your host user is UID 1000, omit `templates/docker/compose.uid-gid.yml` from the merge command. The Compose files will run the upstream `${BENCH_IMAGE}:${BENCH_TAG}` image (default `frappe/bench:latest`) directly, with no build step.

## How the override works

The `compose.uid-gid.yml` override adds a `build:` section that wraps the same upstream image the base file would otherwise run (`BENCH_IMAGE`/`BENCH_TAG`), fixes the local name to `bench:${BENCH_TAG}`, and passes the UID/GID variables:

```yaml
x-customizable-image: &customizable_image
  build:
    context: images/bench
    args:
      BENCH_IMAGE: ${BENCH_IMAGE:-frappe/bench}
      BENCH_TAG: ${BENCH_TAG:-latest}
  image: bench:${BENCH_TAG:-latest}

services:
  configurator:
    <<: *customizable_image
    environment:
      USERID: "${USERID:-1000}"
      GROUPID: "${GROUPID:-1000}"
  frappe:
    <<: *customizable_image
    environment:
      USERID: "${USERID:-1000}"
      GROUPID: "${GROUPID:-1000}"
```

When this override is included, Docker Compose builds the custom image from `images/bench/` (`docker compose -f <rendered> build`, or automatically on `up`) and the entrypoint handles the remapping. When it is omitted, the base `non.prod.compose.yml` references `${BENCH_IMAGE:-frappe/bench}:${BENCH_TAG:-latest}` directly — no build step, no entrypoint wrapper. Either way the upstream image is chosen by the same two variables.
