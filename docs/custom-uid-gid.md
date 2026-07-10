# Custom UID/GID

## The problem

The upstream `frappe/bench` image creates a `frappe` user with UID/GID **1000:1000** baked in at build time. When you bind-mount a host directory into the container, the container user (UID 1000) may not match the host user's UID. This causes:

- **Permission denied** errors when the container tries to write to the mounted volume.
- Need to `chown` host directories to 1000:1000, which conflicts with the host user's own UID and requires `sudo` for日常 file operations.
- Inconsistent behavior between VS Code devcontainers (which auto-remap UID/GID) and standalone Docker Compose deployments.

Changing the UID/GID at runtime requires root privileges (for `usermod`/`groupmod`), which is why the base image runs as `frappe` — there is no way to remap without elevated permissions first.

## The solution

A thin wrapper image (`images/bench/Dockerfile`) extends the upstream `frappe/bench` image:

1. Switches back to `USER root` so the entrypoint has permission to modify users and chown files.
2. Copies in `entrypoint.sh`, which runs at container start.
3. The entrypoint validates `USERID`/`GROUPID`, remaps the `frappe` user, re-owns container filesystem entries, then drops privileges back to `frappe` via `setpriv`.

### Dockerfile (`images/bench/Dockerfile`)

```dockerfile
FROM ${BASE_IMAGE}:${BASE_TAG}   # defaults to frappe/bench:latest

USER root
ENV HOME=/home/frappe
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

Set `USERID` and `GROUPID` in `.env`, build the custom image, and include the override:

```bash
# In .env
USERID=1001
GROUPID=1001

# Build the custom image
docker build --no-cache -t bench:latest images/bench/

# Render compose with the uid-gid override
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

### Without custom UID/GID (default 1000:1000)

If your host user is UID 1000, skip the custom image build and omit `compose.uid-gid.yml` from the merge command. The Compose files will reference the upstream `frappe/bench:latest` image directly.

## How the override works

The `compose.uid-gid.yml` override replaces the image reference and passes the environment variables:

```yaml
x-customizable-image: &customizable_image
  build:
    context: images/bench
    args:
      BASE_IMAGE: ${BASE_IMAGE:-frappe/bench}
      BASE_TAG: ${BASE_TAG:-latest}
  image: ${CUSTOM_IMAGE:-bench}:${CUSTOM_TAG:-latest}

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

When this override is included, Docker builds the custom image from `images/bench/` and the entrypoint handles the remapping. When it is omitted, the base `non.prod.compose.yml` references `${CUSTOM_IMAGE:-frappe/bench}:${CUSTOM_TAG:-latest}` directly — no build step, no entrypoint wrapper.
