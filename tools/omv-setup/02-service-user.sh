#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
need_root

if id "$SVC_USER" >/dev/null 2>&1; then
  log "User '$SVC_USER' already exists"
else
  useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$SVC_GROUP" "$SVC_USER"
  log "Created user '$SVC_USER' (primary group: $SVC_GROUP)"
fi

# Ensure supplementary docker group membership
if id -nG "$SVC_USER" | grep -qw "$DOCKER_GROUP"; then
  log "$SVC_USER already in $DOCKER_GROUP"
else
  usermod -aG "$DOCKER_GROUP" "$SVC_USER"
  log "Added $SVC_USER to $DOCKER_GROUP"
fi
