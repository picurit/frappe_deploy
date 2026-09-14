# Thin layer on top of the upstream frappe/bench image that makes the `frappe` user's
# UID/GID (hardcoded to 1000:1000 in frappe_docker/images/bench/Dockerfile) configurable at
# container-run time, via the USERID/GROUPID environment variables.
#
# Basing this on the built image (rather than duplicating the upstream Dockerfile's apt/pyenv/
# nvm/bench build steps) keeps this file small and needing no maintenance when upstream
# changes - it only adds an entrypoint, it doesn't rebuild the toolchain.
#
# The entrypoint runs as the `frappe` user (inherited from the base image). Root operations
# (usermod, groupmod, chown, setpriv) are performed via sudo re-execution. The frappe user
# has passwordless sudo configured in the base image (frappe_docker/images/bench/Dockerfile:102).
# This means docker compose exec defaults to the frappe user without requiring -u frappe.
# Upstream image to wrap. Passed as build args by templates/docker/compose.uid-gid.yml from the
# BENCH_IMAGE/BENCH_TAG variables in .env (same names as the base compose file).
ARG BENCH_IMAGE=frappe/bench
ARG BENCH_TAG=latest

FROM ${BENCH_IMAGE}:${BENCH_TAG}

# USER, HOME, and PATH are inherited from the base image (USER frappe, HOME=/home/frappe).
# The entrypoint handles sudo env leaks (USER=root, PATH=secure_path) at runtime.
ENV USERID=1000
ENV GROUPID=1000

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
