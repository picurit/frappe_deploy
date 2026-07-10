# Thin layer on top of the upstream frappe/bench image that makes the `frappe` user's
# UID/GID (hardcoded to 1000:1000 in frappe_docker/images/bench/Dockerfile) configurable at
# container-run time, via the USERID/GROUPID environment variables.
#
# Basing this on the built image (rather than duplicating the upstream Dockerfile's apt/pyenv/
# nvm/bench build steps) keeps this file small and needing no maintenance when upstream
# changes - it only adds an entrypoint, it doesn't rebuild the toolchain.
ARG BASE_IMAGE=frappe/bench
ARG BASE_TAG=latest

FROM ${BASE_IMAGE}:${BASE_TAG}

# The base image ends as `USER frappe`. The entrypoint needs root to usermod/groupmod and
# re-chown files before dropping privileges back to frappe via setpriv, so every container
# starts as root again here.
USER root

# Override the HOME that Docker implicitly set to /root when USER root was declared.
# Without this, Python's `site` module would look for user-site packages under /root
# instead of /home/frappe, causing "No module named bench" errors after setpriv drops
# privileges back to the frappe user.
ENV HOME=/home/frappe

# Documents the defaults and lets `docker inspect` / compose show them; entrypoint.sh applies
# the same defaults on its own if these are unset.
ENV USERID=1000
ENV GROUPID=1000

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
