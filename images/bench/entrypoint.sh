#!/usr/bin/env bash
# Remaps the `frappe` user (baked into the base image as UID/GID 1000) to a caller-supplied
# UID/GID before handing off to the container's real command. This lets a single image work
# unmodified against host-mounted volumes owned by any UID/GID, without requiring a custom
# build per host or chown'ing host directories to 1000:1000.
#
# Runs as the `frappe` user (USER frappe in Dockerfile, user: frappe in compose).
# When started as non-root, re-executes itself as root via passwordless sudo so that
# usermod/groupmod/chown/setpriv can run. Before dropping privileges, cleans up env vars
# leaked by sudo -E (USER=root, LOGNAME=root, PATH=secure_path, SUDO_*=*) and restores
# the correct identity so that tools like python-crontab and getpass.getuser() behave
# as the frappe user.
set -euo pipefail

log() {
    echo "entrypoint: $*"
}

# ---------------------------------------------------------------------------
# Non-root bootstrap: re-execute this script as root via sudo.
# This runs BEFORE any usermod, so UID 1000 still exists in /etc/passwd and
# sudo can authenticate the frappe user via its NOPASSWD sudoers rule.
# sudo -E preserves all environment variables (USERID, GROUPID, HOME, DB_HOST,
# etc.) through the re-execution.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log "running as uid=$(id -u), re-executing as root via sudo"
    exec sudo -E "$0" "$@"
fi

TARGET_UID="${USERID:-1000}"
TARGET_GID="${GROUPID:-1000}"

fail() {
    echo "entrypoint: ERROR: $*" >&2
    exit 1
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Clean up env vars injected by sudo -E and restore frappe identity.
# sudo -E sets USER=root, LOGNAME=root and SUDO_*=* even though the process
# will run as frappe after setpriv. It also replaces PATH with secure_path,
# stripping pyenv/nvm/.local/bin. Python's getpass.getuser() picks up
# USER/LOGNAME and would report "root", causing bench to write
# frappe_user: root into common_site_config.json and crash when
# python-crontab tries `crontab -u root -l` without root privileges.
cleanup_env() {
    unset USER LOGNAME SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND
    export USER=frappe
    export LOGNAME=frappe
    # Restore full PATH including pyenv, nvm, and bench.
    # Nvm version is detected dynamically from the base image.
    export PATH="/home/frappe/.nvm/versions/node/$(ls /home/frappe/.nvm/versions/node/ | sort -V | tail -1)/bin:/home/frappe/.local/bin:/home/frappe/.pyenv/shims:/home/frappe/.pyenv/bin:$PATH"
}

log "starting entrypoint as root (USERID=$TARGET_UID GROUPID=$TARGET_GID)"

is_uint "$TARGET_UID" || fail "USERID must be a positive integer, got '$TARGET_UID'"
is_uint "$TARGET_GID" || fail "GROUPID must be a positive integer, got '$TARGET_GID'"
log "validated USERID and GROUPID"

CURRENT_UID="$(id -u frappe)"
CURRENT_GID="$(id -g frappe)"
log "current frappe identity: UID=$CURRENT_UID GID=$CURRENT_GID"

# Fast path: already the requested identity (the default 1000:1000 case included) - skip all
# root-only setup and go straight to running the command as frappe.
if [ "$TARGET_UID" = "$CURRENT_UID" ] && [ "$TARGET_GID" = "$CURRENT_GID" ]; then
    log "UID/GID already match, skipping remap"
    cleanup_env
    exec setpriv --reuid=frappe --regid=frappe --init-groups -- "$@"
fi

log "remapping frappe user: UID $CURRENT_UID -> $TARGET_UID, GID $CURRENT_GID -> $TARGET_GID"

# Reject targets that collide with an already-existing UID/GID (other than frappe's own
# current one, which is what we're about to change).
if [ "$TARGET_UID" != "$CURRENT_UID" ] && getent passwd "$TARGET_UID" >/dev/null 2>&1; then
    fail "USERID $TARGET_UID is already assigned to another user ($(getent passwd "$TARGET_UID" | cut -d: -f1))"
fi
if [ "$TARGET_GID" != "$CURRENT_GID" ] && getent group "$TARGET_GID" >/dev/null 2>&1; then
    fail "GROUPID $TARGET_GID is already assigned to another group ($(getent group "$TARGET_GID" | cut -d: -f1))"
fi
log "no UID/GID collisions detected"

# Work out which group frappe's primary group should end up being.
if [ "$TARGET_GID" = "$CURRENT_GID" ]; then
    # Group unchanged, only the UID moves.
    TARGET_GROUP="$(getent group "$TARGET_GID" | cut -d: -f1)"
    log "group unchanged, using existing group: $TARGET_GROUP"
elif [ "$TARGET_GID" = "$TARGET_UID" ]; then
    # USERID == GROUPID: reuse the existing `frappe` group, just repoint its GID.
    log "repointing frappe group GID: $CURRENT_GID -> $TARGET_GID"
    groupmod -g "$TARGET_GID" frappe
    TARGET_GROUP=frappe
else
    # USERID != GROUPID and, per the checks above, no group already owns GROUPID: create one.
    log "creating new group frappegid with GID $TARGET_GID"
    groupadd -g "$TARGET_GID" frappegid
    TARGET_GROUP=frappegid
fi

log "updating user to frappe:$TARGET_GROUP UID=$TARGET_UID GID=$TARGET_GID"

# Change frappe's numeric UID/GID using usermod/groupmod.
# Temporarily move frappe's home directory to a dummy location, avoiding usermod
# trying to chown the home directory to the new UID/GID, this would be performed
# by the next step using find/chown.
DUMMY_HOME="/tmp/dummy_home_${HOME##*/}"
mkdir -p "$DUMMY_HOME"
usermod -d "$DUMMY_HOME" frappe
usermod -u "$TARGET_UID" -g "$TARGET_GROUP" frappe
usermod -d "$HOME" frappe

log "scanning and updating filesystem ownership (this may take a moment)..."

# Re-owns files matching the old UID/GID only on the container root, skipping host mounts.
# Emits plain-text progress updates every 500 modified files via awk.
# Ensures reliable log rendering when running under multiplexed Docker Compose environments.
{ find / -xdev \( -uid "$CURRENT_UID" -o -gid "$CURRENT_GID" \) \
    -exec chown -hc "$TARGET_UID:$TARGET_GROUP" '{}' + 2>/dev/null || true; } \
    | awk '
        NR % 500 == 0 { printf "entrypoint: re-owned %d files so far...\n", NR; fflush() }
        END          { if (NR > 0) printf "entrypoint: re-owned %d files total\n", NR; fflush() }
    '

log "filesystem re-ownership complete"

cleanup_env

log "dropping privileges to frappe:$TARGET_GROUP ($TARGET_UID:$TARGET_GID) and executing: $*"
exec setpriv --reuid=frappe --regid="$TARGET_GROUP" --init-groups -- "$@"
